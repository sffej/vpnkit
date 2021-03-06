open Lwt.Infix

let src =
  let src = Logs.Src.create "Uwt" ~doc:"Host interface based on Uwt" in
  Logs.Src.set_level src (Some Logs.Debug);
  src

module Log = (val Logs.src_log src : Logs.LOG)

let default_read_buffer_size = 65536

let log_exception_continue description f =
  Lwt.catch
    (fun () -> f ())
    (fun e ->
       Log.err (fun f -> f "%s: caught %s" description (Printexc.to_string e));
       Lwt.return ()
    )

let make_sockaddr (ip, port) =
  let unix = Unix.ADDR_INET (Unix.inet_addr_of_string @@ Ipaddr.to_string ip, port) in
  Uwt_base.Conv.of_unix_sockaddr_exn unix


module Common = struct
  (** FLOW boilerplate *)

  type error = [
    | `Msg of string
  ]

  let error_message = function
    | `Msg x -> x

  let errorf fmt = Printf.ksprintf (fun s -> Lwt.return (`Error (`Msg s))) fmt

  let ip_port_of_sockaddr sockaddr =
    try
      match Uwt_base.Conv.to_unix_sockaddr_exn sockaddr with
      | Unix.ADDR_INET(ip, port) ->
        Some (Ipaddr.of_string @@ Unix.string_of_inet_addr ip, port)
      | _ ->
        None
    with _ -> None

  type 'a io = 'a Lwt.t
  type buffer = Cstruct.t
end

module Sockets = struct

  module Datagram = struct
    type reply = Cstruct.t -> unit Lwt.t

    type flow = {
      description: string;
      fd: Uwt.Udp.t;
      mutable last_use: float;
      (* For protocols like NTP the source port keeps changing, so we send
         replies to the last source port we saw. *)
      mutable reply: reply;
    }

    (* FIXME: deduplicate some of the common code here with Host_lwt_unix *)

    (* Look up by src * src_port * dst * dst_port *)
    let table = Hashtbl.create 7

    let _ =
      let rec loop () =
        Uwt.Timer.sleep 60_000
        >>= fun () ->
        let snapshot = Hashtbl.copy table in
        let now = Unix.gettimeofday () in
        Hashtbl.iter (fun k flow ->
            if now -. flow.last_use > 60. then begin
              Log.debug (fun f -> f "Socket.Datagram %s: expiring UDP NAT rule" flow.description);
              let result = Uwt.Udp.close flow.fd in
              if not(Uwt.Int_result.is_ok result)
              then Log.err (fun f -> f "Socket.Datagram %s: close returned %s" flow.description (Uwt.strerror (Uwt.Int_result.to_error result)));
              Hashtbl.remove table k
            end
          ) snapshot;
        loop () in
      loop ()

    let input ~reply ~src:(src, src_port) ~dst:(dst, dst_port) ~payload =
      (if Hashtbl.mem table (src, src_port, dst, dst_port) then begin
          Lwt.return (Some (Hashtbl.find table (src, src_port, dst, dst_port)))
        end else begin
         let description = Ipaddr.to_string src ^ ":" ^ (string_of_int src_port) ^ "-" ^ (Ipaddr.to_string dst) ^ ":" ^ (string_of_int dst_port) in
         if Ipaddr.compare dst Ipaddr.(V4 V4.broadcast) = 0 then begin
           Log.debug (fun f -> f "Socket.Datagram.input %s: ignoring broadcast packet" description);
           Lwt.return None
         end else begin
           Log.debug (fun f -> f "Socket.Datagram.input %s: creating UDP NAT rule" description);
           let fd = Uwt.Udp.init () in
           let sockaddr = make_sockaddr (Ipaddr.(V4 V4.any), 0) in
           let result = Uwt.Udp.bind ~mode:[ Uwt.Udp.Reuse_addr ] fd ~addr:sockaddr () in
           if not(Uwt.Int_result.is_ok result) then begin
             Log.err (fun f -> f "Socket.Datagram.input: bind returned %s" (Uwt.strerror (Uwt.Int_result.to_error result)));
             Lwt.return None
           end else begin
             let last_use = Unix.gettimeofday () in
             let flow = { description; fd; last_use; reply} in
             Hashtbl.replace table (src, src_port, dst, dst_port) flow;
             (* Start a listener *)
             let buf = Cstruct.create 1500 in
             let rec loop () =
               Lwt.catch
                 (fun () ->
                    Uwt.Udp.recv_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len ~buf:buf.Cstruct.buffer fd
                    >>= fun recv ->
                    if recv.Uwt.Udp.is_partial then begin
                      Log.err (fun f -> f "Socket.Datagram.input %s: dropping partial response" description);
                      Lwt.return true
                    end else if recv.Uwt.Udp.sockaddr = None then begin
                      Log.err (fun f -> f "Socket.Datagram.input %s: dropping response from unknown sockaddr" description);
                      Lwt.return true
                    end else begin
                      flow.reply (Cstruct.sub buf 0 recv.Uwt.Udp.recv_len)
                      >>= fun () ->
                      Lwt.return true
                    end
                 ) (function
                     | Uwt.Uwt_error(Uwt.ECANCELED, _, _) ->
                       (* fd has been closed by the GC *)
                       Log.debug (fun f -> f "Socket.Datagram.input %s: shutting down listening thread" description);
                       Lwt.return false
                     | e ->
                       Log.err (fun f -> f "Socket.Datagram.input %s: caught unexpected exception %s" description (Printexc.to_string e));
                       Lwt.return false
                   )
               >>= function
               | false -> Lwt.return ()
               | true -> loop () in
             Lwt.async loop;
             Lwt.return (Some flow)
           end
         end
       end) >>= function
      | None -> Lwt.return ()
      | Some flow ->
        flow.reply <- reply;
        Lwt.catch
          (fun () ->
             let remote_sockaddr = make_sockaddr (dst, dst_port) in
             Uwt.Udp.send_ba ~pos:payload.Cstruct.off ~len:payload.Cstruct.len ~buf:payload.Cstruct.buffer flow.fd remote_sockaddr
             >>= fun () ->
             flow.last_use <- Unix.gettimeofday ();
             Lwt.return ()
          ) (fun e ->
              Log.err (fun f -> f "Socket.Datagram.input %s: Lwt_bytes.send caught %s" flow.description (Printexc.to_string e));
              Lwt.return ()
            )

    type address = Ipaddr.t * int


    module Udp = struct
      include Common

      type server = {
        fd: Uwt.Udp.t;
        mutable closed: bool;
      }

      let make fd = { fd; closed = false }

      let bind (ip, port) =
        let sockaddr = make_sockaddr(ip, port) in
        let fd = Uwt.Udp.init () in
        let result = Uwt.Udp.bind ~mode:[ Uwt.Udp.Reuse_addr ] fd ~addr:sockaddr () in
        if not(Uwt.Int_result.is_ok result) then begin
          Log.err (fun f -> f "Socket.Datagram.bind returned %s" (Uwt.strerror (Uwt.Int_result.to_error result)));
          Lwt.fail (Uwt.Int_result.to_exn result)
        end else Lwt.return { fd; closed = false }

      let of_bound_fd fd =
        match Uwt.Udp.openudp fd with
        | Uwt.Ok fd -> make fd
        | Uwt.Error error ->
          let msg = Printf.sprintf "Socket.Datagram.of_bound_fd failed with %s" (Uwt.strerror error) in
          Log.err (fun f -> f "%s" msg);
          failwith msg

      let shutdown server =
        if not server.closed then begin
          server.closed <- true;
          let result = Uwt.Udp.close server.fd in
          if not(Uwt.Int_result.is_ok result) then begin
            Log.err (fun f -> f "Socket.Datagram: close returned %s" (Uwt.strerror (Uwt.Int_result.to_error result)));
          end;
        end;
        Lwt.return_unit

      let recvfrom server buf =
        Uwt.Udp.recv_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len ~buf:buf.Cstruct.buffer server.fd
        >>= fun recv ->
        if recv.Uwt.Udp.is_partial then begin
          Log.err (fun f -> f "Socket.Datagram.recvfrom: dropping partial response");
          Lwt.fail (Failure "Socket.Datagram.recvfrom partial response")
        end else match recv.Uwt.Udp.sockaddr with
          | None ->
            Log.err (fun f -> f "Socket.Datagram.recvfrom: dropping response from unknown sockaddr");
            Lwt.fail (Failure "Socket.Datagram.recvfrom unknown sender")
          | Some address ->
            begin match Uwt.Conv.to_unix_sockaddr_exn address with
              | Unix.ADDR_INET(ip, port) ->
                let address = Ipaddr.of_string_exn @@ Unix.string_of_inet_addr ip, port in
                Lwt.return (recv.Uwt.Udp.recv_len, address)
              | _ ->
                assert false
            end

      let sendto server (ip, port) buf =
        let sockaddr = Unix.ADDR_INET(Unix.inet_addr_of_string @@ Ipaddr.to_string ip, port) in
        let sockaddr = Uwt_base.Conv.of_unix_sockaddr_exn sockaddr in
        Uwt.Udp.send_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len ~buf:buf.Cstruct.buffer server.fd sockaddr
    end

  end

  module Stream = struct
    module Tcp = struct
      include Common

      type address = Ipaddr.V4.t * int

      type flow = {
        description: string;
        fd: Uwt.Tcp.t;
        read_buffer_size: int;
        mutable read_buffer: Cstruct.t;
        mutable closed: bool;
      }

      let of_fd ?(read_buffer_size = default_read_buffer_size) ~description fd =
        let read_buffer = Cstruct.create read_buffer_size in
        let closed = false in
        { description; fd; read_buffer; read_buffer_size; closed }

      let connect ?(read_buffer_size = default_read_buffer_size) (ip, port) =
        let fd = Uwt.Tcp.init () in
        let description = Ipaddr.V4.to_string ip ^ ":" ^ (string_of_int port) in
        Lwt.catch
          (fun () ->
             let sockaddr = make_sockaddr (Ipaddr.V4 ip, port) in
             Uwt.Tcp.connect fd ~addr:sockaddr
             >>= fun () ->
             Lwt.return (`Ok (of_fd ~read_buffer_size ~description fd))
          )
          (fun e ->
             (* FIXME(djs55): error handling *)
             let _ = Uwt.Tcp.close fd in
             errorf "Socket.Tcp.connect %s: caught %s" description (Printexc.to_string e)
          )

      let shutdown_read _ =
        Lwt.return ()

      let shutdown_write { description; fd; closed; _ } =
        try
          if not closed then Uwt.Tcp.shutdown fd else Lwt.return ()
        with
        | Unix.Unix_error(Unix.ENOTCONN, _, _) -> Lwt.return ()
        | e ->
          Log.err (fun f -> f "Socket.TCPV4.shutdown_write %s: caught %s returning Eof" description (Printexc.to_string e));
          Lwt.return ()

      let read_into t buf =
        let rec loop buf =
          if Cstruct.len buf = 0
          then Lwt.return (`Ok ())
          else
            Uwt.Tcp.read_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len t.fd ~buf:buf.Cstruct.buffer
            >>= function
            | 0 -> Lwt.return `Eof
            | n ->
              loop (Cstruct.shift buf n) in
        loop buf

      let read t =
        (if Cstruct.len t.read_buffer = 0 then t.read_buffer <- Cstruct.create t.read_buffer_size);
        Lwt.catch
          (fun () ->
             Uwt.Tcp.read_ba ~pos:t.read_buffer.Cstruct.off ~len:t.read_buffer.Cstruct.len t.fd ~buf:t.read_buffer.Cstruct.buffer
             >>= function
             | 0 -> Lwt.return `Eof
             | n ->
               let results = Cstruct.sub t.read_buffer 0 n in
               t.read_buffer <- Cstruct.shift t.read_buffer n;
               Lwt.return (`Ok results)
          ) (fun e ->
              Log.err (fun f -> f "Socket.TCPV4.read %s: caught %s returning Eof" t.description (Printexc.to_string e));
              Lwt.return `Eof
            )

      let write t buf =
        Lwt.catch
          (fun () ->
             Uwt.Tcp.write_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len t.fd ~buf:buf.Cstruct.buffer
             >>= fun () ->
             Lwt.return (`Ok ())
          ) (fun e ->
              Log.err (fun f -> f "Socket.TCPV4.write %s: caught %s returning Eof" t.description (Printexc.to_string e));
              Lwt.return `Eof
            )

      let writev t bufs =
        Lwt.catch
          (fun () ->
             let rec loop = function
               | [] -> Lwt.return (`Ok ())
               | buf :: bufs ->
                 Uwt.Tcp.write_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len t.fd ~buf:buf.Cstruct.buffer
                 >>= fun () ->
                 loop bufs in
             loop bufs
          ) (fun e ->
              Log.err (fun f -> f "Socket.TCPV4.writev %s: caught %s returning Eof" t.description (Printexc.to_string e));
              Lwt.return `Eof
            )

      let close t =
        if not t.closed then begin
          t.closed <- true;
          (* FIXME(djs55): errors *)
          let _ = Uwt.Tcp.close t.fd in
          Lwt.return ()
        end else Lwt.return ()

      type server = {
        mutable listening_fds: Uwt.Tcp.t list;
        read_buffer_size: int;
      }

      let make ?(read_buffer_size = default_read_buffer_size) listening_fds =
        { listening_fds; read_buffer_size }

      let getsockname server = match server.listening_fds with
        | [] -> failwith "Tcp.getsockname: socket is closed"
        | fd :: _ ->
          match Uwt.Conv.to_unix_sockaddr_exn @@ Uwt.Tcp.getsockname_exn fd with
          | Unix.ADDR_INET(iaddr, port) ->
            Ipaddr.V4.of_string_exn (Unix.string_of_inet_addr iaddr), port
          | _ -> invalid_arg "Tcp.getsockname passed a non-TCP socket"

      let bind_one (ip, port) =
        let fd = Uwt.Tcp.init () in
        let addr = make_sockaddr (ip, port) in
        let result = Uwt.Tcp.bind fd ~addr () in
        if not(Uwt.Int_result.is_ok result) then begin
          let error = Uwt.Int_result.to_error result in
          let msg = Printf.sprintf "Socket.Tcp.bind(%s, %d): %s" (Ipaddr.to_string ip) port (Uwt.strerror error) in
          Log.err (fun f -> f "%s" msg);
          if error = Uwt.EADDRINUSE
          then Lwt.fail (Unix.Unix_error(Unix.EADDRINUSE, "bind", ""))
          else Lwt.fail (Failure msg)
        end else Lwt.return fd

      let bind (ip, port) =
        bind_one (Ipaddr.V4 ip, port)
        >>= fun fd ->
        let local_port = match Uwt.Tcp.getsockname fd with
          | Uwt.Ok sockaddr ->
            begin match ip_port_of_sockaddr sockaddr with
              | Some (_, local_port) -> local_port
              | _ -> assert false
            end
          | _ -> assert false in
        (* On some systems localhost will resolve to ::1 first and this can
           cause performance problems (particularly on Windows). Perform a
           best-effort bind to the ::1 address. *)
        Lwt.catch
          (fun () ->
             if Ipaddr.V4.compare ip Ipaddr.V4.localhost = 0
             || Ipaddr.V4.compare ip Ipaddr.V4.any = 0
             then begin
               Log.info (fun f -> f "attempting a best-effort bind of ::1:%d" local_port);
               bind_one (Ipaddr.(V6 V6.localhost), local_port)
               >>= fun fd ->
               Lwt.return [ fd ]
             end else begin
               Lwt.return []
             end
          ) (fun e ->
              Log.info (fun f -> f "ignoring failed bind to ::1:%d (%s)" local_port (Printexc.to_string e));
              Lwt.return []
            )
        >>= fun extra ->
        Lwt.return (make (fd :: extra))

      let shutdown server =
        let fds = server.listening_fds in
        server.listening_fds <- [];
        (* FIXME(djs55): errors *)
        List.iter (fun fd -> ignore (Uwt.Tcp.close fd)) fds;
        Lwt.return ()

      let of_bound_fd ?(read_buffer_size = default_read_buffer_size) fd =
        let fd = Uwt.Tcp.opentcp_exn fd in
        make ~read_buffer_size [ fd ]

      let listen server cb =
        List.iter
          (fun fd ->
             Uwt.Tcp.listen_exn fd ~max:32 ~cb:(fun server x ->
                 if Uwt.Int_result.is_error x then
                   ignore(Uwt_io.printl "listen error")
                 else
                   let client = Uwt.Tcp.init () in
                   let t = Uwt.Tcp.accept_raw ~server ~client in
                   if Uwt.Int_result.is_error t then begin
                     ignore(Uwt_io.printl "accept error");
                   end else begin
                     let flow = of_fd ~description:"connected TCP" client in
                     Lwt.async
                       (fun () ->
                          log_exception_continue "listen"
                            (fun () ->
                               Lwt.finalize
                                 (fun () ->
                                    log_exception_continue "Socket.Stream"
                                      (fun () -> cb flow)
                                 ) (fun () -> close flow)
                            )
                       )
                   end
               );
          ) server.listening_fds

    end

    module Unix = struct
      include Common

      type address = string

      type flow = {
        description: string;
        fd: Uwt.Pipe.t;
        read_buffer_size: int;
        mutable read_buffer: Cstruct.t;
        mutable closed: bool;
      }

      let of_fd ?(read_buffer_size = default_read_buffer_size) ~description fd =
        let read_buffer = Cstruct.create read_buffer_size in
        let closed = false in
        { description; fd; read_buffer; read_buffer_size; closed }

      let unsafe_get_raw_fd t =
        let fd = Uwt.Pipe.fileno_exn t.fd in
        Unix.clear_nonblock fd;
        fd

      let connect ?(read_buffer_size = default_read_buffer_size) path =
        let fd = Uwt.Pipe.init () in
        Uwt.Pipe.connect fd ~path
        >>= fun () ->
        let description = path in
        Lwt.return (`Ok (of_fd ~read_buffer_size ~description fd))

      let shutdown_read _ =
        Lwt.return ()

      let shutdown_write { description; fd; closed; _ } =
        try
          if not closed then Uwt.Pipe.shutdown fd else Lwt.return ()
        with
        | Unix.Unix_error(Unix.ENOTCONN, _, _) -> Lwt.return ()
        | e ->
          Log.err (fun f -> f "Socket.Pipe.shutdown_write %s: caught %s returning Eof" description (Printexc.to_string e));
          Lwt.return ()

      let read_into t buf =
        let rec loop buf =
          if Cstruct.len buf = 0
          then Lwt.return (`Ok ())
          else
            Uwt.Pipe.read_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len t.fd ~buf:buf.Cstruct.buffer
            >>= function
            | 0 -> Lwt.return `Eof
            | n ->
              loop (Cstruct.shift buf n) in
        loop buf

      let read t =
        (if Cstruct.len t.read_buffer = 0 then t.read_buffer <- Cstruct.create t.read_buffer_size);
        Lwt.catch
          (fun () ->
             Uwt.Pipe.read_ba ~pos:t.read_buffer.Cstruct.off ~len:t.read_buffer.Cstruct.len t.fd ~buf:t.read_buffer.Cstruct.buffer
             >>= function
             | 0 -> Lwt.return `Eof
             | n ->
               let results = Cstruct.sub t.read_buffer 0 n in
               t.read_buffer <- Cstruct.shift t.read_buffer n;
               Lwt.return (`Ok results)
          ) (fun e ->
              Log.err (fun f -> f "Socket.Pipe.read %s: caught %s returning Eof" t.description (Printexc.to_string e));
              Lwt.return `Eof
            )

      let write t buf =
        Lwt.catch
          (fun () ->
             Uwt.Pipe.write_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len t.fd ~buf:buf.Cstruct.buffer
             >>= fun () ->
             Lwt.return (`Ok ())
          ) (fun e ->
              Log.err (fun f -> f "Socket.Pipe.write %s: caught %s returning Eof" t.description (Printexc.to_string e));
              Lwt.return `Eof
            )

      let writev t bufs =
        Lwt.catch
          (fun () ->
             let rec loop = function
               | [] -> Lwt.return (`Ok ())
               | buf :: bufs ->
                 Uwt.Pipe.write_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len t.fd ~buf:buf.Cstruct.buffer
                 >>= fun () ->
                 loop bufs in
             loop bufs
          ) (fun e ->
              Log.err (fun f -> f "Socket.Pipe.writev %s: caught %s returning Eof" t.description (Printexc.to_string e));
              Lwt.return `Eof
            )

      let close t =
        if not t.closed then begin
          t.closed <- true;
          (* FIXME(djs55): errors *)
          let _ = Uwt.Pipe.close t.fd in
          Lwt.return ()
        end else Lwt.return ()

      type server = {
        fd: Uwt.Pipe.t;
        mutable closed: bool;
      }

      let bind path =
        Lwt.catch
          (fun () ->
             Uwt.Fs.unlink path
          ) (fun _ -> Lwt.return ())
        >>= fun () ->
        let fd = Uwt.Pipe.init () in
        Uwt.Pipe.bind_exn fd ~path;
        Lwt.return { fd; closed = false }

      let listen { fd; _ } cb =
        Uwt.Pipe.listen_exn fd ~max:5 ~cb:(fun server x ->
            if Uwt.Int_result.is_error x then
              ignore(Uwt_io.printl "listen error")
            else
              let client = Uwt.Pipe.init () in
              let t = Uwt.Pipe.accept_raw ~server ~client in
              if Uwt.Int_result.is_error t then begin
                ignore(Uwt_io.printl "accept error");
              end else begin
                Lwt.async
                  (fun () ->
                     log_exception_continue "Pipe.listen"
                       (fun () ->
                          let conn = of_fd ~description:"Pipe connection" client in
                          cb conn
                          >>= fun () ->
                          ignore(Uwt.Pipe.close client);
                          Lwt.return ()
                       )
                  )
              end
          )

      let of_bound_fd ?(read_buffer_size = default_read_buffer_size) fd =
        match Uwt.Pipe.openpipe fd with
        | Uwt.Ok fd -> { fd; closed = false }
        | Uwt.Error error ->
          let msg = Printf.sprintf "Socket.Pipe.of_bound_fd (read_buffer_size=%d) failed with %s" read_buffer_size (Uwt.strerror error) in
          Log.err (fun f -> f "%s" msg);
          failwith msg

      let shutdown server =
        if not server.closed then begin
          server.closed <- true;
          (* FIXME(djs55): errors *)
          ignore(Uwt.Pipe.close server.fd)
        end;
        Lwt.return ()

      let getsockname server = match Uwt.Pipe.getsockname server.fd with
        | Uwt.Ok path ->
          path
        | _ -> invalid_arg "Unix.sockname passed a non-Unix socket"


    end
  end
end

module Files = struct
  let read_file path =
    let open Lwt.Infix in
    Lwt.catch
      (fun () ->
         Uwt.Fs.openfile ~mode:[ Uwt.Fs_types.O_RDONLY ] path
         >>= fun file ->
         let buffer = Buffer.create 128 in
         let frag = Bytes.make 1024 ' ' in
         Lwt.finalize
           (fun () ->
              let rec loop () =
                Uwt.Fs.read file ~buf:frag
                >>= function
                | 0 ->
                  Lwt.return (`Ok (Buffer.contents buffer))
                | n ->
                  Buffer.add_substring buffer frag 0 n;
                  loop () in
              loop ()
           ) (fun () ->
               Uwt.Fs.close file
             )
      ) (fun e ->
          Lwt.return (`Error (`Msg (Printf.sprintf "reading %s: %s" path (Printexc.to_string e))))
        )
end

module Time = struct
  type 'a io = 'a Lwt.t

  let sleep secs = Uwt.Timer.sleep (int_of_float (secs *. 1000.))
end

module Main = struct
  let run = Uwt.Main.run
  let run_in_main = Uwt_preemptive.run_in_main
end
