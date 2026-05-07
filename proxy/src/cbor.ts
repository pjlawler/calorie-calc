// Minimal CBOR decoder — only what App Attest needs (maps, arrays, byte strings,
// text strings, unsigned ints). No tags, no floats, no negative ints, no streaming.
// Spec: RFC 8949.

type CBORValue = number | string | Uint8Array | CBORValue[] | { [k: string]: CBORValue };

class Reader {
  pos = 0;
  constructor(public buf: Uint8Array) {}

  u8(): number {
    if (this.pos >= this.buf.length) throw new Error("cbor: truncated");
    return this.buf[this.pos++]!;
  }

  bytes(n: number): Uint8Array {
    if (this.pos + n > this.buf.length) throw new Error("cbor: truncated");
    const out = this.buf.subarray(this.pos, this.pos + n);
    this.pos += n;
    return out;
  }

  // Read a length-or-immediate value following a CBOR initial byte's low 5 bits.
  len(low: number): number {
    if (low < 24) return low;
    if (low === 24) return this.u8();
    if (low === 25) return (this.u8() << 8) | this.u8();
    if (low === 26) {
      const a = this.u8(), b = this.u8(), c = this.u8(), d = this.u8();
      return a * 0x1000000 + ((b << 16) | (c << 8) | d);
    }
    throw new Error(`cbor: unsupported length ${low}`);
  }
}

function decode(r: Reader): CBORValue {
  const ib = r.u8();
  const major = ib >> 5;
  const low = ib & 0x1f;

  switch (major) {
    case 0: return r.len(low); // unsigned int
    case 2: return r.bytes(r.len(low)); // byte string
    case 3: return new TextDecoder().decode(r.bytes(r.len(low))); // text string
    case 4: { // array
      const n = r.len(low);
      const out: CBORValue[] = [];
      for (let i = 0; i < n; i++) out.push(decode(r));
      return out;
    }
    case 5: { // map
      const n = r.len(low);
      const out: { [k: string]: CBORValue } = {};
      for (let i = 0; i < n; i++) {
        const k = decode(r);
        if (typeof k !== "string") throw new Error("cbor: non-string map key");
        out[k] = decode(r);
      }
      return out;
    }
    default:
      throw new Error(`cbor: unsupported major type ${major}`);
  }
}

export function decodeCBOR(buf: Uint8Array): CBORValue {
  const r = new Reader(buf);
  const v = decode(r);
  if (r.pos !== buf.length) throw new Error("cbor: trailing bytes");
  return v;
}
