(* sha256.ml — Pure OCaml SHA-256 (FIPS 180-4), no external crypto.

   Word-level arithmetic uses Int32: every add wraps modulo 2^32 and
   `shift_right_logical` gives the unsigned shift required by the
   specification. The 64 round constants are the fractional parts of the
   cube roots of the first 64 primes, and the initial state is the
   fractional parts of the square roots of the first 8 primes, as
   specified. *)

let k_constants : Int32.t array =
  [|
    0x428a2f98l; 0x71374491l; 0xb5c0fbcfl; 0xe9b5dba5l; 0x3956c25bl;
    0x59f111f1l; 0x923f82a4l; 0xab1c5ed5l; 0xd807aa98l; 0x12835b01l;
    0x243185bel; 0x550c7dc3l; 0x72be5d74l; 0x80deb1fel; 0x9bdc06a7l;
    0xc19bf174l; 0xe49b69c1l; 0xefbe4786l; 0x0fc19dc6l; 0x240ca1ccl;
    0x2de92c6fl; 0x4a7484aal; 0x5cb0a9dcl; 0x76f988dal; 0x983e5152l;
    0xa831c66dl; 0xb00327c8l; 0xbf597fc7l; 0xc6e00bf3l; 0xd5a79147l;
    0x06ca6351l; 0x14292967l; 0x27b70a85l; 0x2e1b2138l; 0x4d2c6dfcl;
    0x53380d13l; 0x650a7354l; 0x766a0abbl; 0x81c2c92el; 0x92722c85l;
    0xa2bfe8a1l; 0xa81a664bl; 0xc24b8b70l; 0xc76c51a3l; 0xd192e819l;
    0xd6990624l; 0xf40e3585l; 0x106aa070l; 0x19a4c116l; 0x1e376c08l;
    0x2748774cl; 0x34b0bcb5l; 0x391c0cb3l; 0x4ed8aa4al; 0x5b9cca4fl;
    0x682e6ff3l; 0x748f82eel; 0x78a5636fl; 0x84c87814l; 0x8cc70208l;
    0x90befffal; 0xa4506cebl; 0xbef9a3f7l; 0xc67178f2l;
  |]

let h_init : Int32.t array =
  [| 0x6a09e667l; 0xbb67ae85l; 0x3c6ef372l; 0xa54ff53al; 0x510e527fl;
     0x9b05688cl; 0x1f83d9abl; 0x5be0cd19l |]

let rotr (x : Int32.t) (n : int) : Int32.t =
  Int32.logor (Int32.shift_right_logical x n) (Int32.shift_left x (32 - n))

let ch (x : Int32.t) (y : Int32.t) (z : Int32.t) : Int32.t =
  Int32.logxor (Int32.logand x y) (Int32.logand (Int32.lognot x) z)

let maj (x : Int32.t) (y : Int32.t) (z : Int32.t) : Int32.t =
  Int32.logxor (Int32.logand x y)
    (Int32.logxor (Int32.logand x z) (Int32.logand y z))

let bsig0 (x : Int32.t) : Int32.t =
  Int32.logxor (rotr x 2) (Int32.logxor (rotr x 13) (rotr x 22))

let bsig1 (x : Int32.t) : Int32.t =
  Int32.logxor (rotr x 6) (Int32.logxor (rotr x 11) (rotr x 25))

let ssig0 (x : Int32.t) : Int32.t =
  Int32.logxor (rotr x 7) (Int32.logxor (rotr x 18) (Int32.shift_right_logical x 3))

let ssig1 (x : Int32.t) : Int32.t =
  Int32.logxor (rotr x 17) (Int32.logxor (rotr x 19) (Int32.shift_right_logical x 10))

let be32 (block : Bytes.t) (off : int) : Int32.t =
  let b0 = Char.code (Bytes.get block off) in
  let b1 = Char.code (Bytes.get block (off + 1)) in
  let b2 = Char.code (Bytes.get block (off + 2)) in
  let b3 = Char.code (Bytes.get block (off + 3)) in
  Int32.logor (Int32.shift_left (Int32.of_int b0) 24)
    (Int32.logor (Int32.shift_left (Int32.of_int b1) 16)
       (Int32.logor (Int32.shift_left (Int32.of_int b2) 8)
          (Int32.of_int b3)))

(* One 512-bit block. `w` is reused so block processing allocates nothing
   per call (the million-'a' vector runs ~15625 blocks). *)
let process_block (state : Int32.t array) (w : Int32.t array) (block : Bytes.t)
    (off : int) : unit =
  for i = 0 to 15 do
    w.(i) <- be32 block (off + (4 * i))
  done;
  for i = 16 to 63 do
    w.(i) <-
      Int32.add
        (Int32.add w.(i - 16) (ssig0 w.(i - 15)))
        (Int32.add w.(i - 7) (ssig1 w.(i - 2)))
  done;
  let a = ref state.(0) and b = ref state.(1) in
  let c = ref state.(2) and d = ref state.(3) in
  let e = ref state.(4) and f = ref state.(5) in
  let g = ref state.(6) and h = ref state.(7) in
  for i = 0 to 63 do
    let t1 =
      Int32.add (Int32.add !h (bsig1 !e))
        (Int32.add (ch !e !f !g) (Int32.add k_constants.(i) w.(i)))
    in
    let t2 = Int32.add (bsig0 !a) (maj !a !b !c) in
    h := !g;
    g := !f;
    f := !e;
    e := Int32.add !d t1;
    d := !c;
    c := !b;
    b := !a;
    a := Int32.add t1 t2
  done;
  state.(0) <- Int32.add state.(0) !a;
  state.(1) <- Int32.add state.(1) !b;
  state.(2) <- Int32.add state.(2) !c;
  state.(3) <- Int32.add state.(3) !d;
  state.(4) <- Int32.add state.(4) !e;
  state.(5) <- Int32.add state.(5) !f;
  state.(6) <- Int32.add state.(6) !g;
  state.(7) <- Int32.add state.(7) !h

(* RFC 4634 / NIST-style big-endian 64-bit length field. *)
let write_be64 (block : Bytes.t) (off : int) (v : Int64.t) : unit =
  for i = 0 to 7 do
    let shift = 8 * (7 - i) in
    let byte = Int64.logand (Int64.shift_right_logical v shift) 0xFFL in
    Bytes.set block (off + i) (Char.chr (Int64.to_int byte))
  done

(* SHA-256 of the raw bytes; 64 lowercase hex characters. *)
let digest_bytes (input : Bytes.t) : string =
  let n = Bytes.length input in
  let bit_len = Int64.mul (Int64.of_int n) 8L in
  let rem = n mod 64 in
  let pad_len = if rem < 56 then 56 - rem else 120 - rem in
  let padded_len = n + pad_len + 8 in
  (* Bytes.create is documented to return arbitrary bytes; the padding
     region must be explicit zeros. *)
  let padded = Bytes.create padded_len in
  Bytes.fill padded 0 padded_len (Char.chr 0x00);
  Bytes.blit input 0 padded 0 n;
  Bytes.set padded n (Char.chr 0x80);
  write_be64 padded (padded_len - 8) bit_len;
  let state = Array.copy h_init in
  let w = Array.make 64 0l in
  let rec go off =
    if off < padded_len then begin
      process_block state w padded off;
      go (off + 64)
    end
  in
  go 0;
  let buf = Buffer.create 64 in
  Array.iter (fun word -> Buffer.add_string buf (Printf.sprintf "%08lx" word)) state;
  Buffer.contents buf

let digest (s : string) : string = digest_bytes (Bytes.of_string s)
