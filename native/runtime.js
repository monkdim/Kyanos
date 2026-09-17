/**
 * Clarity Runtime — JavaScript builtins for transpiled Clarity code.
 *
 * Hand-maintained, and the source of truth for what a builtin does. It was
 * once generated from stdlib/runtime_spec.clarity; the spec drifted, the
 * generator would have overwritten fixes that live only here, and it has been
 * retired. A builtin added here must also be registered in interpreter.clarity,
 * bytecode.clarity, type_checker.clarity and both transpiler import headers --
 * stdlib/test_runtime_surface.clarity fails if one of them is missed.
 */

import { readFileSync, writeFileSync, appendFileSync, existsSync, readdirSync, mkdirSync, unlinkSync, renameSync, statSync } from 'fs';
import { execSync, spawnSync } from 'child_process';
import { createInterface } from 'readline';
import { createServer } from 'http';
import { resolve, dirname, basename, extname, join as pathJoin, sep } from 'path';
import { createHash, randomUUID } from 'crypto';
import { dlopen, FFIType, suffix as ffiSuffix, ptr as bunPtr, read as bunRead, CString, JSCallback } from 'bun:ffi';

// ── I/O ──────────────────────────────────────────────────

const _output = [];

export function show(...vals) {
  const text = vals.map(display).join(' ');
  console.log(text);
  _output.push(text);
}

export { show as print };

export function ask(prompt = '') {
  process.stdout.write(prompt);
  const buf = Buffer.alloc(1024);
  const fd = process.platform === 'win32'
    ? process.stdin.fd
    : require('fs').openSync('/dev/tty', 'rs');
  let n = 0;
  try { n = require('fs').readSync(fd, buf, 0, buf.length, null); } catch { }
  if (fd !== process.stdin.fd) require('fs').closeSync(fd);
  return buf.slice(0, n).toString().replace(/[\r\n]+$/, '');
}

export function read(path) { return readFileSync(path, 'utf-8'); }
export function write(path, content) { writeFileSync(path, display(content)); return true; }
export function append(path, content) { appendFileSync(path, display(content)); return true; }
export function exists(path) { return existsSync(path); }
export function lines(path) { return readFileSync(path, 'utf-8').split('\n'); }
export function read_bytes(path) { return Array.from(readFileSync(path)); }
export function write_bytes(path, bytes) { writeFileSync(path, Buffer.from(bytes)); return true; }
export function read_mem(pid, addr, len) {
  if (len <= 0) return [];
  const _fs = require('fs');
  const path = (pid && pid > 0) ? `/proc/${pid}/mem` : '/proc/self/mem';
  let fd;
  try { fd = _fs.openSync(path, 'r'); } catch { return []; }
  try {
    const buf = Buffer.alloc(len);
    const n = _fs.readSync(fd, buf, 0, len, addr);
    return Array.from(buf.subarray(0, n));
  } catch { return []; }
  finally { try { _fs.closeSync(fd); } catch { } }
}
export function write_mem(pid, addr, bytes) {
  if (!bytes || bytes.length === 0) return 0;
  const _fs = require('fs');
  const path = (pid && pid > 0) ? `/proc/${pid}/mem` : '/proc/self/mem';
  let fd;
  try { fd = _fs.openSync(path, 'r+'); } catch { return 0; }
  try {
    const buf = Buffer.from(bytes.map(b => b & 0xFF));
    return _fs.writeSync(fd, buf, 0, buf.length, addr);
  } catch { return 0; }
  finally { try { _fs.closeSync(fd); } catch { } }
}

// ── Type conversions ─────────────────────────────────────

export function $int(v) {
  if (typeof v === 'string') {
    const s = v.trim();
    if (/^[+-]?0x/i.test(s)) return parseInt(s, 16) || 0;
    if (/^[+-]?0o/i.test(s)) return parseInt(s.replace(/0o/i, ''), 8) || 0;
    if (/^[+-]?0b/i.test(s)) return parseInt(s.replace(/0b/i, ''), 2) || 0;
    return parseInt(s, 10) || 0;
  }
  return Math.trunc(Number(v));
}

export function $float(v) { return parseFloat(v); }
export function str(v) { return display(v); }
export function $bool(v) { return truthy(v); }

export function $eq(a, b) {
  if (a === b) return true;
  // Treat null and undefined as equal (Clarity only has null)
  if (a == null || b == null) return a == null && b == null;
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!$eq(a[i], b[i])) return false;
    return true;
  }
  if (typeof a === 'object' && typeof b === 'object') {
    if (a.constructor !== Object || b.constructor !== Object) return false;
    const ka = Object.keys(a);
    if (ka.length !== Object.keys(b).length) return false;
    for (const k of ka) if (!$eq(a[k], b[k])) return false;
    return true;
  }
  return false;
}

export function $ne(a, b) { return !$eq(a, b); }

export function $index(obj, idx) {
  if ((Array.isArray(obj) || typeof obj === 'string') && typeof idx === 'number' && idx < 0) {
    idx = obj.length + idx;
  }
  const v = obj == null ? undefined : obj[idx];
  return v === undefined ? null : v;
}
export function type(v) {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'boolean') return 'bool';
  if (typeof v === 'number') return Number.isInteger(v) ? 'int' : 'float';
  if (typeof v === 'string') return 'string';
  if (Array.isArray(v)) return 'list';
  if (v instanceof ClarityEnum) return 'enum';
  if (v instanceof ClarityInstance) return v._className;
  if (typeof v === 'function') return 'function';
  // Check for interpreter class instances by their _clarityType marker
  if (typeof v === 'object' && v._clarityType) {
    return v._clarityType;
  }
  if (typeof v === 'object') return 'map';
  return 'unknown';
}

// ── Collections ──────────────────────────────────────────

export function len(v) {
  if (v === null || v === undefined) return 0;
  if (typeof v === 'string' || Array.isArray(v)) return v.length;
  if (typeof v === 'object') return Object.keys(v).length;
  return 0;
}

export function push(list, item) { list.push(item); return list; }
export function pop(list) { return list.pop(); }
export function sort(list) { return [...list].sort((a, b) => a < b ? -1 : a > b ? 1 : 0); }
export function reverse(v) {
  if (typeof v === 'string') return v.split('').reverse().join('');
  return [...v].reverse();
}

export function range(...args) {
  let start = 0, end = 0, step = 1;
  if (args.length === 1) { end = args[0]; }
  else if (args.length === 2) { start = args[0]; end = args[1]; }
  else { start = args[0]; end = args[1]; step = args[2]; }
  const result = [];
  if (step > 0) for (let i = start; i < end; i += step) result.push(i);
  else for (let i = start; i > end; i += step) result.push(i);
  return result;
}

export function map(list, fn) { return list.map((v, i) => fn(v, i)); }
export function filter(list, fn) { return list.filter(fn); }
export function reduce(list, fn, init) {
  return init !== undefined ? list.reduce(fn, init) : list.reduce(fn);
}
export function each(list, fn) { list.forEach(fn); }
export function find(list, fn) { return list.find(fn) ?? null; }
export function every(list, fn) { return list.every(fn); }
export function some(list, fn) { return list.some(fn); }
export function flat(list) { return list.flat(); }
export function zip(...lists) {
  const minLen = Math.min(...lists.map(l => l.length));
  return Array.from({ length: minLen }, (_, i) => lists.map(l => l[i]));
}
export function unique(list) { return [...new Set(list)]; }
export function keys(obj) { return Object.keys(obj); }
export function values(obj) { return Object.values(obj); }
export function entries(obj) { return Object.entries(obj); }
export function merge(...objs) { return Object.assign({}, ...objs); }
export function has(obj, key) {
  if (Array.isArray(obj)) return obj.includes(key);
  if (typeof obj === 'string') return obj.includes(key);
  return obj != null && key in obj;
}

// ── Strings ──────────────────────────────────────────────

export function split(s, sep = ' ') { return s.split(sep); }
export function $join(list, sep = '') { return list.map(display).join(sep); }
export function replace(s, from, to) { return s.split(from).join(to); }
export function trim(s) { return s.trim(); }
export function upper(s) { return s.toUpperCase(); }
export function lower(s) { return s.toLowerCase(); }
export function contains(s, sub) {
  if (Array.isArray(s)) return s.includes(sub);
  return s.includes(sub);
}
export function starts(s, prefix) { return s.startsWith(prefix); }
export function ends(s, suffix) { return s.endsWith(suffix); }
export function chars(s) { return s.split(''); }
export function $repeat(s, n) { return s.repeat(n); }
export function pad_left(s, n, ch = ' ') { return s.padStart(n, ch); }
export function pad_right(s, n, ch = ' ') { return s.padEnd(n, ch); }
export function char_at(s, i) { return s[i] ?? null; }
export function char_code(s) { return s.charCodeAt(0); }
export function from_char_code(n) { return String.fromCharCode(n); }
export function index_of(s, sub) { return s.indexOf(sub); }
export function substring(s, start, end) { return s.substring(start, end); }
export function is_digit(c) { return c.length > 0 && /^\d+$/.test(c); }
export function is_alpha(c) { return c.length > 0 && /^[a-zA-Z]+$/.test(c); }
export function is_alnum(c) { return c.length > 0 && /^[a-zA-Z0-9]+$/.test(c); }
export function is_space(c) { return c.length > 0 && /^\s+$/.test(c); }

// ── Math ─────────────────────────────────────────────────

export const pi = Math.PI;
export const e = Math.E;
export const sqrt = Math.sqrt;
export const sin = Math.sin;
export const cos = Math.cos;
export const tan = Math.tan;
export const log = Math.log;
export function abs(n) { return Math.abs(n); }
export function round(n, d = 0) { const f = 10 ** d; return Math.round(n * f) / f; }
export function floor(n) { return Math.floor(n); }
export function ceil(n) { return Math.ceil(n); }
export function $min(...args) {
  if (args.length === 1 && Array.isArray(args[0])) return Math.min(...args[0]);
  return Math.min(...args);
}
export function $max(...args) {
  if (args.length === 1 && Array.isArray(args[0])) return Math.max(...args[0]);
  return Math.max(...args);
}
export function sum(list) { return list.reduce((a, b) => a + b, 0); }
export function random(...args) {
  if (args.length === 0) return Math.random();
  if (args.length === 1) return Math.floor(Math.random() * args[0]);
  return Math.floor(Math.random() * (args[1] - args[0])) + args[0];
}
export function pow(base, exp) { return base ** exp; }

// ── System ───────────────────────────────────────────────

export function exec(cmd) {
  try { return execSync(cmd, { encoding: 'utf-8' }).replace(/\n$/, ''); }
  catch (e) { return e.stdout || ''; }
}

export function exec_full(cmd) {
  try {
    const stdout = execSync(cmd, { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] });
    return { stdout, stderr: '', exit_code: 0 };
  } catch (e) {
    return { stdout: e.stdout || '', stderr: e.stderr || '', exit_code: e.status || 1 };
  }
}

export function exit(code = 0) { process.exit(code); }
export function sleep(secs) { execSync(`sleep ${secs}`); }
export function time() { return Date.now() / 1000; }

// ── PTY: a real pseudo-terminal for the terminal app ─────
// Spawns a child (a shell) on a pseudo-terminal so the terminal emulator
// can drive raw-mode programs, not just line-buffered pipes. Uses
// openpty (libutil) + posix_spawn — posix_spawn never runs JS in the
// child (unlike forkpty), so the Bun runtime is never left forked.
// These builtins are NOT in runtime_spec.clarity (they carry module
// state); runtime.js is the canonical, build-copied runtime.
let _ptyLib = null;
function _pty_lib() {
  if (_ptyLib) return _ptyLib;
  const plat = process.platform;
  let cfg;
  if (plat === 'linux') {
    cfg = { util: 'libutil.so.1', libc: 'libc.so.6', TIOCSWINSZ: 0x5414, O_NONBLOCK: 0o4000, F_SETFL: 4 };
  } else if (plat === 'darwin') {
    cfg = { util: 'libutil.dylib', libc: 'libSystem.dylib', TIOCSWINSZ: 0x80087467, O_NONBLOCK: 0x0004, F_SETFL: 4 };
  } else {
    throw new Error('PtyError: pseudo-terminals are not supported on ' + plat);
  }
  const util = dlopen(cfg.util, { openpty: { args: ['ptr', 'ptr', 'ptr', 'ptr', 'ptr'], returns: 'int' } });
  const libc = dlopen(cfg.libc, {
    posix_spawn: { args: ['ptr', 'cstring', 'ptr', 'ptr', 'ptr', 'ptr'], returns: 'int' },
    posix_spawn_file_actions_init: { args: ['ptr'], returns: 'int' },
    posix_spawn_file_actions_adddup2: { args: ['ptr', 'int', 'int'], returns: 'int' },
    read: { args: ['int', 'ptr', 'u64'], returns: 'i64' },
    write: { args: ['int', 'ptr', 'u64'], returns: 'i64' },
    close: { args: ['int'], returns: 'int' },
    fcntl: { args: ['int', 'int', 'int'], returns: 'int' },
    ioctl: { args: ['int', 'u64', 'ptr'], returns: 'int' },
    waitpid: { args: ['int', 'ptr', 'int'], returns: 'int' },
    kill: { args: ['int', 'int'], returns: 'int' },
  });
  _ptyLib = { util, libc, cfg };
  return _ptyLib;
}

// PTY support is verified on Linux; macOS constants are wired but gated
// pending a run on real hardware, so callers can degrade gracefully.
export function _pty_supported() { return process.platform === 'linux'; }

const _ptySessions = new Map();   // master fd -> { pid, exited, status }
function _pty_enc(s) { const bb = Buffer.from(String(s), 'utf-8'); const u = new Uint8Array(bb.length + 1); u.set(bb); return u; }

// Spawn `path` (argv a list, cols×rows the window size). Returns
// { master, pid }. `master` is a non-blocking fd to read/write.
export function _pty_spawn(path, argv, cols, rows) {
  const L = _pty_lib();
  const { util, libc } = L;
  const mfd = new Int32Array(1), sfd = new Int32Array(1);
  const ws = new Uint16Array(4); ws[0] = (rows | 0) || 24; ws[1] = (cols | 0) || 80;
  if (util.symbols.openpty(bunPtr(mfd), bunPtr(sfd), 0, 0, bunPtr(ws)) !== 0) {
    throw new Error('PtyError: openpty failed');
  }
  const master = mfd[0], slave = sfd[0];
  const fa = new Uint8Array(1024);
  libc.symbols.posix_spawn_file_actions_init(bunPtr(fa));
  libc.symbols.posix_spawn_file_actions_adddup2(bunPtr(fa), slave, 0);
  libc.symbols.posix_spawn_file_actions_adddup2(bunPtr(fa), slave, 1);
  libc.symbols.posix_spawn_file_actions_adddup2(bunPtr(fa), slave, 2);
  const args = (argv && argv.length) ? argv : [path];
  const argBufs = args.map(_pty_enc);
  const argvArr = new BigUint64Array(argBufs.length + 1);
  argBufs.forEach((b, i) => { argvArr[i] = BigInt(bunPtr(b)); });
  const envList = ['TERM=xterm-256color'];
  for (const k of ['PATH', 'HOME', 'LANG', 'USER', 'SHELL']) if (process.env[k]) envList.push(k + '=' + process.env[k]);
  const envBufs = envList.map(_pty_enc);
  const envArr = new BigUint64Array(envBufs.length + 1);
  envBufs.forEach((b, i) => { envArr[i] = BigInt(bunPtr(b)); });
  const pathBuf = _pty_enc(path);
  const pidbuf = new Int32Array(1);
  const rc = libc.symbols.posix_spawn(bunPtr(pidbuf), bunPtr(pathBuf), bunPtr(fa), 0, bunPtr(argvArr), bunPtr(envArr));
  libc.symbols.close(slave);
  if (rc !== 0) { libc.symbols.close(master); throw new Error('PtyError: posix_spawn failed (rc=' + rc + ')'); }
  libc.symbols.fcntl(master, L.cfg.F_SETFL, L.cfg.O_NONBLOCK);
  _ptySessions.set(master, { pid: pidbuf[0], exited: false, status: 0 });
  return { master, pid: pidbuf[0] };
}

// Read available bytes without blocking. Returns a string of new output,
// "" if nothing is ready yet, or null once the child has closed the PTY.
export function _pty_read(master, maxlen) {
  const L = _pty_lib();
  const n = Math.max(1, Math.min((maxlen | 0) || 65536, 1 << 20));
  const buf = new Uint8Array(n);
  const got = Number(L.libc.symbols.read(master, bunPtr(buf), BigInt(n)));
  if (got > 0) return Buffer.from(buf.subarray(0, got)).toString('utf-8');
  if (got === 0) return null;
  return '';
}

export function _pty_write(master, text) {
  const L = _pty_lib();
  const bb = Buffer.from(String(text), 'utf-8');
  const u = new Uint8Array(bb.length); u.set(bb);
  return Number(L.libc.symbols.write(master, bunPtr(u), BigInt(u.length)));
}

export function _pty_resize(master, cols, rows) {
  const L = _pty_lib();
  const ws = new Uint16Array(4); ws[0] = rows | 0; ws[1] = cols | 0;
  return L.libc.symbols.ioctl(master, BigInt(L.cfg.TIOCSWINSZ), bunPtr(ws));
}

// Non-blocking reap: returns true while the child runs, false once it has
// exited (and reaps it so it doesn't linger as a zombie).
export function _pty_poll(master) {
  const L = _pty_lib();
  const s = _ptySessions.get(master);
  if (!s || s.exited) return false;
  const st = new Int32Array(1);
  const r = L.libc.symbols.waitpid(s.pid, bunPtr(st), 1 /* WNOHANG */);
  if (r === s.pid) { s.exited = true; s.status = st[0]; return false; }
  return true;
}

export function _pty_close(master) {
  const L = _pty_lib();
  const s = _ptySessions.get(master);
  if (s && !s.exited) { L.libc.symbols.kill(s.pid, 9); }
  L.libc.symbols.close(master);
  _ptySessions.delete(master);
  return true;
}

// ── Host window: run KyanOS in a real OS window (SDL2) ───
// Opens a native window, uploads the composed framebuffer to a streaming
// texture, and turns SDL input into desktop events. The framebuffer is
// BGRA in memory, which is exactly SDL_PIXELFORMAT_ARGB8888 on a
// little-endian host — so pixels upload with no conversion. Encapsulated
// as builtins (like PTY) so the app loop stays in Clarity.
let _hostState = null;
function _host_sdl() {
  if (_hostState && _hostState.S) return _hostState;
  let name;
  if (process.platform === 'linux') name = 'libSDL2-2.0.so.0';
  else if (process.platform === 'darwin') name = 'libSDL2-2.0.dylib';
  else if (process.platform === 'win32') name = 'SDL2.dll';
  else throw new Error('HostError: no SDL2 for platform ' + process.platform);
  const S = dlopen(name, {
    SDL_Init: { args: ['u32'], returns: 'int' },
    SDL_Quit: { args: [], returns: 'void' },
    SDL_GetError: { args: [], returns: 'cstring' },
    SDL_CreateWindow: { args: ['cstring', 'int', 'int', 'int', 'int', 'u32'], returns: 'ptr' },
    SDL_CreateRenderer: { args: ['ptr', 'int', 'u32'], returns: 'ptr' },
    SDL_CreateTexture: { args: ['ptr', 'u32', 'int', 'int', 'int'], returns: 'ptr' },
    SDL_UpdateTexture: { args: ['ptr', 'ptr', 'ptr', 'int'], returns: 'int' },
    SDL_RenderClear: { args: ['ptr'], returns: 'int' },
    SDL_RenderCopy: { args: ['ptr', 'ptr', 'ptr', 'ptr'], returns: 'int' },
    SDL_RenderPresent: { args: ['ptr'], returns: 'void' },
    SDL_PollEvent: { args: ['ptr'], returns: 'int' },
    SDL_StartTextInput: { args: [], returns: 'void' },
    SDL_GetTicks: { args: [], returns: 'u32' },
    SDL_Delay: { args: ['u32'], returns: 'void' },
    SDL_DestroyTexture: { args: ['ptr'], returns: 'void' },
    SDL_DestroyRenderer: { args: ['ptr'], returns: 'void' },
    SDL_DestroyWindow: { args: ['ptr'], returns: 'void' },
  });
  _hostState = { S, win: null, ren: null, tex: null, w: 0, h: 0, ev: new Uint8Array(64) };
  return _hostState;
}

export function _host_supported() {
  return process.platform === 'linux' || process.platform === 'darwin' || process.platform === 'win32';
}

// SDL keycode → the name the desktop/games expect (mirrors browser e.key).
function _host_key_name(sym) {
  switch (sym) {
    case 0x4000004F: return 'ArrowRight';
    case 0x40000050: return 'ArrowLeft';
    case 0x40000051: return 'ArrowDown';
    case 0x40000052: return 'ArrowUp';
    case 13: return 'Enter';
    case 27: return 'Escape';
    case 8: return 'Backspace';
    case 9: return 'Tab';
    case 32: return ' ';
    case 0x400000E3: return 'Meta';   // Left GUI (Super/Cmd/Win)
    case 0x400000E7: return 'Meta';   // Right GUI
  }
  if (sym >= 33 && sym <= 126) return String.fromCharCode(sym);
  return '';
}

export function _host_open(title, w, h) {
  const st = _host_sdl();
  if (st.win) return true;
  if (st.S.symbols.SDL_Init(0x20 /* VIDEO */) !== 0) throw new Error('HostError: SDL_Init: ' + st.S.symbols.SDL_GetError().toString());
  const t = _pty_enc(String(title || 'KyanOS'));
  const CENTERED = 0x2FFF0000;
  st.win = st.S.symbols.SDL_CreateWindow(bunPtr(t), CENTERED, CENTERED, w | 0, h | 0, 0x4 /* SHOWN */ | 0x20 /* RESIZABLE */);
  if (!st.win) throw new Error('HostError: CreateWindow: ' + st.S.symbols.SDL_GetError().toString());
  st.ren = st.S.symbols.SDL_CreateRenderer(st.win, -1, 0);
  st.tex = st.S.symbols.SDL_CreateTexture(st.ren, 0x16362004 /* ARGB8888 */, 1 /* STREAMING */, w | 0, h | 0);
  st.w = w | 0; st.h = h | 0;
  st.S.symbols.SDL_StartTextInput();
  return true;
}

export function _host_present(fbHandle, w, h) {
  const st = _host_sdl();
  if (!st.ren || !fbHandle || !fbHandle._buffer) return false;
  // the framebuffer resized (a live window resize): rebuild the texture
  if (!st.tex || st.w !== (w | 0) || st.h !== (h | 0)) {
    if (st.tex) st.S.symbols.SDL_DestroyTexture(st.tex);
    st.tex = st.S.symbols.SDL_CreateTexture(st.ren, 0x16362004, 1, w | 0, h | 0);
    st.w = w | 0; st.h = h | 0;
  }
  st.S.symbols.SDL_UpdateTexture(st.tex, 0, bunPtr(fbHandle._buffer), (w | 0) * 4);
  st.S.symbols.SDL_RenderClear(st.ren);
  st.S.symbols.SDL_RenderCopy(st.ren, st.tex, 0, 0);
  st.S.symbols.SDL_RenderPresent(st.ren);
  return true;
}

// Pop one pending event as a plain object, or null when the queue is empty.
export function _host_poll() {
  const st = _host_sdl();
  const ev = st.ev;
  if (st.S.symbols.SDL_PollEvent(bunPtr(ev)) === 0) return null;
  const dv = new DataView(ev.buffer);
  const type = dv.getUint32(0, true);
  if (type === 0x100) return { type: 'quit' };
  if (type === 0x200) {                                   // SDL_WINDOWEVENT
    const wev = ev[12];
    if (wev === 5 || wev === 6) return { type: 'resize', w: dv.getInt32(16, true), h: dv.getInt32(20, true) };
    return { type: 'other', code: 'win' };
  }
  if (type === 0x300 || type === 0x301) {
    const sym = dv.getInt32(20, true);
    return { type: 'key', down: type === 0x300, name: _host_key_name(sym), sym };
  }
  if (type === 0x303) {                                   // SDL_TEXTINPUT
    let s = ''; let i = 12;
    while (i < 44 && ev[i] !== 0) { s += String.fromCharCode(ev[i]); i++; }
    return { type: 'text', text: Buffer.from(s, 'binary').toString('utf-8') };
  }
  if (type === 0x400) return { type: 'mouse', kind: 'motion', x: dv.getInt32(20, true), y: dv.getInt32(24, true), button: 0 };
  if (type === 0x401 || type === 0x402) {
    return { type: 'mouse', kind: type === 0x401 ? 'down' : 'up', x: dv.getInt32(20, true), y: dv.getInt32(24, true), button: ev[16] };
  }
  return { type: 'other', code: type };
}

export function _host_ticks() { return _host_sdl().S.symbols.SDL_GetTicks(); }
export function _host_delay(ms) { _host_sdl().S.symbols.SDL_Delay(ms | 0); }

export function _host_close() {
  const st = _hostState;
  if (!st || !st.S) return true;
  if (st.tex) st.S.symbols.SDL_DestroyTexture(st.tex);
  if (st.ren) st.S.symbols.SDL_DestroyRenderer(st.ren);
  if (st.win) st.S.symbols.SDL_DestroyWindow(st.win);
  st.S.symbols.SDL_Quit();
  _hostState = null;
  return true;
}
export function env(name, def) { const v = process.env[name]; if (v !== undefined) return v; return def === undefined ? null : def; }
export function args() { return process.argv.slice(2); }
export function cwd() { return process.cwd(); }

// ── JSON ─────────────────────────────────────────────────

export function json_parse(s) { return JSON.parse(s); }
export function json_string(v, indent) { return JSON.stringify(v, null, indent); }

// ── Crypto / Encoding ────────────────────────────────────

export function hash(text, algo = 'sha256') {
  return createHash(algo).update(text).digest('hex');
}
export function encode64(text) { return Buffer.from(text).toString('base64'); }
export function decode64(text) { return Buffer.from(text, 'base64').toString(); }

// ── Functional ───────────────────────────────────────────

export function compose(...fns) {
  return (x) => fns.reduceRight((v, fn) => fn(v), x);
}
export function tap(v, fn) { fn(v); return v; }

// ── Set ──────────────────────────────────────────────────

export function $set(list) { return [...new Set(list)]; }

// ── Error ────────────────────────────────────────────────

export function error(msg) { return new Error(msg); }

// ── HTTP ─────────────────────────────────────────────────

export function fetch(url) {
  return execSync(`curl -sL '${url}'`, { encoding: 'utf-8' });
}

// The handler is called with one argument: the request, as a map with
// `method` and `path`. Both callers in this repository — net.clarity's
// HttpServer.listen and registry.clarity's create_handler — were written
// against that shape and read `req.method` and `req.path`, while this
// passed the method and the URL as two separate strings, so a handler
// received "GET" where it expected a request and read a property off a
// string. Nothing caught it because `serve` was not a builtin the
// interpreter offered, so neither caller had ever run.
export function serve(port, handler) {
  const server = createServer((req, res) => {
    const result = handler({ method: req.method, path: req.url });
    if (typeof result === 'object' && result !== null) {
      res.writeHead(result.status || 200, { 'Content-Type': result.type || 'text/html' });
      res.end(result.body || '');
    } else {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(display(result));
    }
  });
  server.listen(port);
  console.log(`  Serving on http://localhost:${port}`);
}

// ── Regex ────────────────────────────────────────────────

export function regex_match(pattern, str) { return new RegExp(pattern).test(str); }
export function regex_search(pattern, str) { return new RegExp(pattern).test(str); }
export function regex_find(pattern, str) { return [...str.matchAll(new RegExp(pattern, 'g'))].map(m => m[0]); }
export function regex_replace(pattern, str, repl) { return str.replace(new RegExp(pattern, 'g'), repl); }
export function regex_split(pattern, str) { return str.split(new RegExp(pattern)); }
// Run a command with this process's terminal as its stdin, stdout and
// stderr, and return its exit status. exec and exec_full capture output
// and feed no input, which is right for `ls` and wrong for QEMU with a
// serial console on stdio: `clarity os run` went through exec_full and
// showed nothing until QEMU exited. This is the one builtin for programs
// a person interacts with.
export function exec_tty(cmd) {
  const r = spawnSync(cmd, { shell: true, stdio: 'inherit' });
  return r.status === null ? 1 : r.status;
}

export function exec_full_regex(pattern, str) {
  const re = new RegExp(pattern);
  const m = re.exec(str);
  if (!m) return null;
  return { match: m[0], groups: m.slice(1), index: m.index };
}

// ── Classes support ──────────────────────────────────────

export class ClarityInstance {
  constructor(className, props = {}) {
    this._className = className;
    Object.assign(this, props);
  }
}

export class ClarityEnum {
  constructor(name, members) {
    this.name = name;
    this.members = members;
    // Expose enum members as properties: Color.RED, Color.GREEN, etc.
    for (const [k, v] of Object.entries(members)) {
      this[k] = v;
    }
  }
  toString() { return `<enum ${this.name}>`; }
}

// ── Path module ──────────────────────────────────────────

export const $path = {
  join: pathJoin,
  dir: dirname,
  name: basename,
  stem: (p) => basename(p, extname(p)),
  ext: extname,
  exists: existsSync,
  is_file: (p) => { try { return statSync(p).isFile(); } catch { return false; } },
  is_dir: (p) => { try { return statSync(p).isDirectory(); } catch { return false; } },
  abs: resolve,
  sep,
};

// ── OS module ────────────────────────────────────────────

export const $os = {
  env: (n) => process.env[n] || null,
  cwd: () => process.cwd(),
  args: () => process.argv.slice(2),
  exec: exec,
  ls: (p = '.') => readdirSync(p),
  mkdir: (p) => mkdirSync(p, { recursive: true }),
  rm: unlinkSync,
  rename: renameSync,
  home: () => process.env.HOME || process.env.USERPROFILE || '/',
  sep,
};

// ── Display helpers ──────────────────────────────────────

export function display(value) {
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') {
    if (Number.isInteger(value)) return String(value);
    return String(value);
  }
  if (typeof value === 'string') return value;
  // repr, not display, for the elements: a string inside a container is
  // shown quoted, the same as the object branch below already does and the
  // same as both other backends do. Displaying them bare made ["a", "b"]
  // print as [a, b] here and as ["a", "b"] everywhere else.
  if (Array.isArray(value)) return '[' + value.map(repr).join(', ') + ']';
  if (value instanceof ClarityEnum) return value.toString();
  if (value instanceof ClarityInstance) return `<${value._className} instance>`;
  if (typeof value === 'function') return `<fn ${value.name || 'anonymous'}>`;
  if (typeof value === 'object') {
    const pairs = Object.entries(value).map(([k, v]) => `${k}: ${repr(v)}`);
    return '{' + pairs.join(', ') + '}';
  }
  return String(value);
}

export function repr(value) {
  if (typeof value === 'string') return `"${value}"`;
  return display(value);
}

export function truthy(value) {
  if (value === null || value === undefined) return false;
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  if (typeof value === 'string') return value.length > 0;
  if (Array.isArray(value)) return value.length > 0;
  return true;
}

// ── Signal classes for control flow ──────────────────────

export class BreakSignal {}
export class ContinueSignal {}
export class ReturnSignal { constructor(value) { this.value = value; } }

// ── Error formatting with Clarity source mapping ─────────

/**
 * Parse /*@file:line*​/ comments from transpiled JS source to build
 * a readable Clarity stack trace.
 */
export function formatClarityError(err, source) {
  if (!(err instanceof Error)) return display(err);
  const jsStack = err.stack || '';
  const lines = jsStack.split('\n');

  // Extract Clarity source locations from the error's JS stack
  const clarityFrames = [];
  const linePattern = /at\s+(?:(\S+)\s+)?\(?.*?:(\d+):\d+\)?/;
  for (const line of lines) {
    const m = line.match(linePattern);
    if (m) {
      const fnName = m[1] || '<module>';
      clarityFrames.push(`  at ${fnName}`);
    }
  }

  let msg = `\x1b[31m\n  Clarity Error: ${err.message}\x1b[0m`;
  if (clarityFrames.length > 0) {
    msg += '\n' + clarityFrames.slice(0, 8).join('\n');
  }
  return msg;
}

/**
 * Wrap the entry point to catch errors and display Clarity-formatted traces.
 */
// ── Embedded standard library ────────────────────────────
// The bundle carries the source of every standard-library module, so a
// program can `from "collections.clarity" import Set` from a directory that
// holds no such file. Until this existed the single binary could run the
// toolchain and nothing else: every library import needed the repository
// checked out beside the program. The entry point registers the map before
// the CLI loads; a bare `bun` run of the sources leaves it empty, and imports
// resolve from disk as they always did.
let _embedded_stdlib = {};
export function _register_embedded_stdlib(map) { _embedded_stdlib = map || {}; }
export function _embedded_source(name) {
  return Object.prototype.hasOwnProperty.call(_embedded_stdlib, name) ? _embedded_stdlib[name] : null;
}
// The executable running this program: the compiled binary's own path, or
// bun's when the sources run uncompiled. The smoke runner uses it to test
// the binary it is part of, from any directory, with no argument.
export function _host_exe() { return process.execPath; }

export function clarityMain(fn) {
  try {
    fn();
  } catch (err) {
    if (err instanceof BreakSignal || err instanceof ContinueSignal || err instanceof ReturnSignal) return;
    console.error(formatClarityError(err));
    process.exit(1);
  }
}

// ── FFI: Bun-backed C interop ────────────────────────────
// Maps Clarity type strings to Bun's FFIType enum.
const $FFI_TYPES = {
  void: FFIType.void,
  bool: FFIType.bool,
  int: FFIType.i32,
  i8: FFIType.i8, i16: FFIType.i16, i32: FFIType.i32, i64: FFIType.i64,
  u8: FFIType.u8, u16: FFIType.u16, u32: FFIType.u32, u64: FFIType.u64,
  float: FFIType.f32, f32: FFIType.f32, f64: FFIType.f64, double: FFIType.f64,
  ptr: FFIType.ptr, pointer: FFIType.ptr,
  string: FFIType.cstring, cstring: FFIType.cstring,
  char: FFIType.char,
};

function $ffi_type(name) {
  if (!(name in $FFI_TYPES)) {
    throw new Error(`FFIError: Unknown type '${name}'`);
  }
  return $FFI_TYPES[name];
}

// Resolve a library name to a path Bun's dlopen can load. "libc" and a few
// well-known names are mapped to the platform-correct shared library.
function $ffi_resolve_lib(name) {
  if (name.includes('/') || name.includes('.')) return name;
  if (name === 'libc' || name === 'c') {
    if (process.platform === 'darwin') return 'libSystem.dylib';
    if (process.platform === 'linux') return 'libc.so.6';
    if (process.platform === 'win32') return 'msvcrt.dll';
  }
  if (name === 'libm' || name === 'm') {
    if (process.platform === 'darwin') return 'libSystem.dylib';
    if (process.platform === 'linux') return 'libm.so.6';
  }
  return `${name}.${ffiSuffix}`;
}

// Open a shared library. Returns a handle ({ symbols, close }).
export function _ffi_open(libname, symbols_spec) {
  const path = $ffi_resolve_lib(libname);
  const symbols = {};
  for (const sym of Object.keys(symbols_spec)) {
    const spec = symbols_spec[sym];
    symbols[sym] = {
      args: (spec.args || []).map($ffi_type),
      returns: $ffi_type(spec.returns || 'void'),
    };
  }
  return dlopen(path, symbols);
}

// Bind a single symbol from a library and return a Clarity-callable function.
// args and ret are arrays/strings of Clarity type names.
export function _ffi_bind(libname, sym_name, args, ret) {
  const handle = _ffi_open(libname, { [sym_name]: { args: args || [], returns: ret || 'void' } });
  const fn = handle.symbols[sym_name];
  if (!fn) throw new Error(`FFIError: Symbol '${sym_name}' not found in '${libname}'`);
  const argTypes = (args || []).slice();
  return (...callArgs) => {
    // Marshal arguments: JS strings → null-terminated UTF-8 buffers for
    // cstring/string params; Pointer wrappers → their numeric addr; pass
    // primitives through unchanged.
    const marshalled = callArgs.map((a, i) => {
      const t = argTypes[i];
      if ((t === 'string' || t === 'cstring') && typeof a === 'string') {
        const bytes = new TextEncoder().encode(a);
        const buf = new Uint8Array(bytes.length + 1);
        buf.set(bytes);
        return buf;
      }
      if (a !== null && typeof a === 'object') {
        return _ffi_addr(a);
      }
      return a;
    });
    const result = fn(...marshalled);
    if (typeof result === 'object' && result !== null && typeof result.toString === 'function' && ret === 'cstring') {
      return result.toString();
    }
    // Bun returns u64/i64 as BigInt; coerce to Number so it interops with
    // the rest of Clarity's numeric stack.
    if (typeof result === 'bigint') return Number(result);
    return result;
  };
}

export function _ffi_close(handle) {
  if (handle && typeof handle.close === 'function') handle.close();
}

// ── FFI: Pointer & memory marshalling ────────────────────
// Pointer handles are JS objects: { addr, _buffer, size }.
// _buffer is non-null when this runtime allocated the memory and holds it
// alive against GC. addr is a numeric (or BigInt) address suitable for
// passing across the FFI boundary.

// Resolve any kind of "pointer-like" thing to a raw numeric address.
// For runtime-allocated buffers we ALWAYS recompute via bunPtr(buffer)
// because the JS engine moves TypedArrays during GC; caching the
// address gives back stale memory when read later.
function _ffi_addr(p) {
  if (p === null || p === undefined) return 0;
  if (typeof p === 'number' || typeof p === 'bigint') return p;
  if (typeof p === 'object') {
    if (p._buffer) return bunPtr(p._buffer);
    if ('addr' in p) return p.addr;
    // Clarity Pointer / Callback / StructInstance wrap the handle in
    // properties._handle (Clarity instance shape).
    if (p.properties && p.properties._handle) return _ffi_addr(p.properties._handle);
  }
  return p;
}

// Allocations use Buffer.allocUnsafeSlow (not Uint8Array, not Buffer.alloc):
// - JavaScriptCore moves TypedArrays during GC, silently invalidating any
//   address captured via bunPtr().
// - Buffer.alloc uses an internal pool for small (< 4KB) allocations
//   that can be relocated/reused, with the same problem.
// allocUnsafeSlow always returns a standalone, non-pooled buffer that
// stays at one address. We zero-fill ourselves since "unsafe" means
// "don't pre-fill".
export function _ffi_alloc(size) {
  const buffer = Buffer.allocUnsafeSlow(size).fill(0);
  return { _buffer: buffer, size };
}

export function _ffi_alloc_cstring(s) {
  const len = Buffer.byteLength(s, 'utf-8');
  const buffer = Buffer.allocUnsafeSlow(len + 1).fill(0);
  buffer.write(s, 0, 'utf-8');
  return { _buffer: buffer, size: buffer.length };
}

export function _ffi_read_cstring(p) {
  const addr = _ffi_addr(p);
  if (!addr) return null;
  return new CString(addr).toString();
}

export function _ffi_ptr_addr(p) { return _ffi_addr(p); }

// Reads. For runtime-owned buffers we read through the underlying DataView
// so writes go through the same view (Bun's read.* sometimes can't see
// modifications made via JS DataView writes on the same Uint8Array).
function _ffi_read_view(p) {
  if (typeof p === 'object' && p !== null && p._buffer) {
    return new DataView(p._buffer.buffer, p._buffer.byteOffset, p._buffer.byteLength);
  }
  return null;
}

export function _ffi_read_u8(p, offset = 0)  { const v = _ffi_read_view(p); return v ? v.getUint8(offset) : bunRead.u8(_ffi_addr(p), offset); }
export function _ffi_read_i8(p, offset = 0)  { const v = _ffi_read_view(p); return v ? v.getInt8(offset)  : bunRead.i8(_ffi_addr(p), offset); }
export function _ffi_read_u16(p, offset = 0) { const v = _ffi_read_view(p); return v ? v.getUint16(offset, true) : bunRead.u16(_ffi_addr(p), offset); }
export function _ffi_read_i16(p, offset = 0) { const v = _ffi_read_view(p); return v ? v.getInt16(offset, true)  : bunRead.i16(_ffi_addr(p), offset); }
export function _ffi_read_u32(p, offset = 0) { const v = _ffi_read_view(p); return v ? v.getUint32(offset, true) : bunRead.u32(_ffi_addr(p), offset); }
export function _ffi_read_i32(p, offset = 0) { const v = _ffi_read_view(p); return v ? v.getInt32(offset, true)  : bunRead.i32(_ffi_addr(p), offset); }
export function _ffi_read_i64(p, offset = 0) { const v = _ffi_read_view(p); return v ? Number(v.getBigInt64(offset, true))  : Number(bunRead.i64(_ffi_addr(p), offset)); }
export function _ffi_read_u64(p, offset = 0) { const v = _ffi_read_view(p); return v ? Number(v.getBigUint64(offset, true)) : Number(bunRead.u64(_ffi_addr(p), offset)); }
export function _ffi_read_f32(p, offset = 0) { const v = _ffi_read_view(p); return v ? v.getFloat32(offset, true) : bunRead.f32(_ffi_addr(p), offset); }
export function _ffi_read_f64(p, offset = 0) { const v = _ffi_read_view(p); return v ? v.getFloat64(offset, true) : bunRead.f64(_ffi_addr(p), offset); }
export function _ffi_read_ptr(p, offset = 0) { return bunRead.ptr(_ffi_addr(p), offset); }

function _ffi_view(p) {
  if (typeof p !== 'object' || !p._buffer) {
    throw new Error('FFIError: cannot write through a pointer this runtime did not allocate');
  }
  return new DataView(p._buffer.buffer, p._buffer.byteOffset, p._buffer.byteLength);
}

export function _ffi_write_u8(p, offset, val)  { _ffi_view(p).setUint8(offset, val); }
export function _ffi_write_i8(p, offset, val)  { _ffi_view(p).setInt8(offset, val); }
export function _ffi_write_u16(p, offset, val) { _ffi_view(p).setUint16(offset, val, true); }
export function _ffi_write_i16(p, offset, val) { _ffi_view(p).setInt16(offset, val, true); }
export function _ffi_write_u32(p, offset, val) { _ffi_view(p).setUint32(offset, val, true); }
export function _ffi_write_i32(p, offset, val) { _ffi_view(p).setInt32(offset, val, true); }
export function _ffi_write_i64(p, offset, val) { _ffi_view(p).setBigInt64(offset, BigInt(val), true); }
export function _ffi_write_u64(p, offset, val) { _ffi_view(p).setBigUint64(offset, BigInt(val), true); }
export function _ffi_write_f32(p, offset, val) { _ffi_view(p).setFloat32(offset, val, true); }
export function _ffi_write_f64(p, offset, val) { _ffi_view(p).setFloat64(offset, val, true); }

// Bulk fill a region of an owned pointer with a u32 pattern. Much faster
// than calling write_u32 in a Clarity loop — used by Framebuffer.clear and
// fill_rect to set hundreds of thousands of pixels at native speed.
export function _ffi_fill_u32(p, byte_offset, count, value) {
  if (!p || !p._buffer) {
    throw new Error('FFIError: fill_u32 requires a runtime-allocated pointer');
  }
  const buf = p._buffer;
  const pattern = Buffer.alloc(4);
  pattern.writeUInt32LE((value >>> 0), 0);
  // Buffer.fill repeats the 4-byte pattern across [start, end).
  buf.fill(pattern, byte_offset, byte_offset + count * 4);
}

// Source-over alpha blend a solid color across `count` 32-bit BGRA
// pixels starting at `byte_offset`. `color` is 0xAARRGGBB; the
// destination is treated as opaque, so results are opaque. Native
// loop — this is the compositor's translucent hot path (glass panels,
// soft shadows, scrims), which must not be an interpreted per-pixel
// loop in Clarity.
export function _ffi_blend_u32(p, byte_offset, count, color) {
  if (!p || !p._buffer) {
    throw new Error('FFIError: blend_u32 requires a runtime-allocated pointer');
  }
  const buf = p._buffer;
  const c = color >>> 0;
  const sa = (c >>> 24) & 0xFF;
  if (sa === 0) return;
  if (sa === 255) {
    const pattern = Buffer.alloc(4);
    pattern.writeUInt32LE(c, 0);
    buf.fill(pattern, byte_offset, byte_offset + count * 4);
    return;
  }
  const sr = (c >>> 16) & 0xFF;
  const sg = (c >>> 8) & 0xFF;
  const sb = c & 0xFF;
  const ia = 255 - sa;
  let o = byte_offset;
  for (let i = 0; i < count; i++) {
    // memory order is B, G, R, A (little-endian 0xAARRGGBB)
    buf[o]     = (sb * sa + buf[o]     * ia) / 255 | 0;
    buf[o + 1] = (sg * sa + buf[o + 1] * ia) / 255 | 0;
    buf[o + 2] = (sr * sa + buf[o + 2] * ia) / 255 | 0;
    buf[o + 3] = 255;
    o += 4;
  }
}

// Separable box blur of a framebuffer's BGRA buffer, in place. `passes`
// box passes approximate a gaussian (2 ≈ soft frosted glass). Running-sum,
// so cost is O(pixels) regardless of radius; edges replicate. This is the
// frosted-glass hot path — a per-pixel Clarity loop was ~50x too slow to
// run every frame.
export function _ffi_box_blur(p, width, height, radius, passes) {
  if (!p || !p._buffer) {
    throw new Error('FFIError: box_blur requires a runtime-allocated pointer');
  }
  if (radius < 1) return;
  const buf = p._buffer;
  const w = width | 0, h = height | 0, r = radius | 0;
  const win = 2 * r + 1;
  const line = new Int32Array(Math.max(w, h) * 3);
  for (let pass = 0; pass < passes; pass++) {
    // horizontal
    for (let y = 0; y < h; y++) {
      const row = y * w * 4;
      for (let x = 0; x < w; x++) { const o = row + x * 4; line[x*3]=buf[o+2]; line[x*3+1]=buf[o+1]; line[x*3+2]=buf[o]; }
      let sr = 0, sg = 0, sb = 0;
      for (let i = -r; i <= r; i++) { const c = i < 0 ? 0 : (i >= w ? w-1 : i); sr+=line[c*3]; sg+=line[c*3+1]; sb+=line[c*3+2]; }
      for (let x = 0; x < w; x++) {
        const o = row + x * 4;
        buf[o]=(sb/win)|0; buf[o+1]=(sg/win)|0; buf[o+2]=(sr/win)|0; buf[o+3]=255;
        const oi = x - r, ii = x + r + 1;
        const oc = oi < 0 ? 0 : oi, ic = ii >= w ? w-1 : ii;
        sr += line[ic*3]-line[oc*3]; sg += line[ic*3+1]-line[oc*3+1]; sb += line[ic*3+2]-line[oc*3+2];
      }
    }
    // vertical
    for (let x = 0; x < w; x++) {
      for (let y = 0; y < h; y++) { const o = (y*w+x)*4; line[y*3]=buf[o+2]; line[y*3+1]=buf[o+1]; line[y*3+2]=buf[o]; }
      let sr = 0, sg = 0, sb = 0;
      for (let i = -r; i <= r; i++) { const c = i < 0 ? 0 : (i >= h ? h-1 : i); sr+=line[c*3]; sg+=line[c*3+1]; sb+=line[c*3+2]; }
      for (let y = 0; y < h; y++) {
        const o = (y*w+x)*4;
        buf[o]=(sb/win)|0; buf[o+1]=(sg/win)|0; buf[o+2]=(sr/win)|0; buf[o+3]=255;
        const oi = y - r, ii = y + r + 1;
        const oc = oi < 0 ? 0 : oi, ic = ii >= h ? h-1 : ii;
        sr += line[ic*3]-line[oc*3]; sg += line[ic*3+1]-line[oc*3+1]; sb += line[ic*3+2]-line[oc*3+2];
      }
    }
  }
}

// Composite `src` (srcW×srcH BGRA) into `dst` (dstW×dstH) at rect
// (dx,dy,dw,dh), bilinear-scaled, source-over at global `alpha` (0-255).
// The compositor's animation path — a window scales up and fades in on
// open — so it must be native, not an interpreted per-pixel loop.
export function _ffi_blit_scaled_alpha(dstP, dstW, dstH, srcP, srcW, srcH, dx, dy, dw, dh, alpha) {
  if (!dstP || !dstP._buffer || !srcP || !srcP._buffer) {
    throw new Error('FFIError: blit_scaled_alpha requires runtime-allocated pointers');
  }
  const a = alpha | 0;
  if (a <= 0 || dw <= 0 || dh <= 0) return;
  const d = dstP._buffer, s = srcP._buffer;
  const DW = dstW | 0, DH = dstH | 0, SW = srcW | 0, SH = srcH | 0;
  const x0 = Math.max(0, dx | 0), y0 = Math.max(0, dy | 0);
  const x1 = Math.min(DW, (dx + dw) | 0), y1 = Math.min(DH, (dy + dh) | 0);
  if (x1 <= x0 || y1 <= y0) return;
  const ia = 255 - a;
  for (let y = y0; y < y1; y++) {
    let fv = ((y - dy) / dh) * SH; if (fv < 0) fv = 0;
    let sy = fv | 0; let vy = fv - sy;
    let sy2 = sy + 1; if (sy2 >= SH) { sy2 = SH - 1; }
    if (sy >= SH) { sy = SH - 1; }
    const rowd = y * DW * 4, row0 = sy * SW * 4, row1 = sy2 * SW * 4;
    for (let x = x0; x < x1; x++) {
      let fu = ((x - dx) / dw) * SW; if (fu < 0) fu = 0;
      let sx = fu | 0; let ux = fu - sx;
      let sx2 = sx + 1; if (sx2 >= SW) { sx2 = SW - 1; }
      if (sx >= SW) { sx = SW - 1; }
      const c0 = row0 + sx * 4, c1 = row0 + sx2 * 4, c2 = row1 + sx * 4, c3 = row1 + sx2 * 4;
      const w00 = (1 - ux) * (1 - vy), w10 = ux * (1 - vy), w01 = (1 - ux) * vy, w11 = ux * vy;
      const b = (s[c0]*w00 + s[c1]*w10 + s[c2]*w01 + s[c3]*w11) | 0;
      const g = (s[c0+1]*w00 + s[c1+1]*w10 + s[c2+1]*w01 + s[c3+1]*w11) | 0;
      const r = (s[c0+2]*w00 + s[c1+2]*w10 + s[c2+2]*w01 + s[c3+2]*w11) | 0;
      const o = rowd + x * 4;
      if (a === 255) { d[o]=b; d[o+1]=g; d[o+2]=r; d[o+3]=255; }
      else { d[o]=(b*a+d[o]*ia)/255|0; d[o+1]=(g*a+d[o+1]*ia)/255|0; d[o+2]=(r*a+d[o+2]*ia)/255|0; d[o+3]=255; }
    }
  }
}

// Bulk copy from one owned (or wrapped) pointer to an owned destination.
export function _ffi_copy(dst, dst_offset, src, src_offset, length) {
  if (!dst || !dst._buffer) {
    throw new Error('FFIError: copy destination must be a runtime-allocated pointer');
  }
  const dbuf = dst._buffer;
  if (src && src._buffer) {
    src._buffer.copy(dbuf, dst_offset, src_offset, src_offset + length);
    return;
  }
  // Foreign source — pull bytes one at a time through bunRead.
  const addr = _ffi_addr(src);
  for (let i = 0; i < length; i++) {
    dbuf[dst_offset + i] = bunRead.u8(addr, src_offset + i);
  }
}

// Write the buffer's bytes to a file path. Useful for save_bmp and friends.
export function _ffi_write_buffer(p, path) {
  if (!p || !p._buffer) {
    throw new Error('FFIError: write_buffer requires a runtime-allocated pointer');
  }
  writeFileSync(path, p._buffer);
}

// Read a file as raw bytes into a Pointer-shaped handle. Handy for
// inspecting binary outputs and as a building block for image loaders.
export function _ffi_read_buffer(path) {
  const data = readFileSync(path);
  return { _buffer: data, size: data.length };
}

// Drop the JS-side buffer reference. The OS-level memory is reclaimed by GC.
// For pointers we didn't allocate (no _buffer), this is a no-op.
export function _ffi_pointer_release(p) {
  if (typeof p === 'object' && p !== null) p._buffer = null;
}

// Wrap a Clarity function as a C callback. The returned handle has an
// `addr` field suitable for passing to a `ptr` parameter, and a `_callback`
// reference that owns the underlying JSCallback (kept alive against GC
// for the lifetime of the handle).
export function _ffi_callback(fn, args, ret) {
  const cb = new JSCallback(fn, {
    args: (args || []).map($ffi_type),
    returns: $ffi_type(ret || 'void'),
  });
  return { addr: cb.ptr, _callback: cb };
}

export function _ffi_callback_close(handle) {
  if (handle && handle._callback) {
    handle._callback.close();
    handle._callback = null;
  }
}
