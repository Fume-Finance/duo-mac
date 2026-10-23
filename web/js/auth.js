// This iPhone's key for the Mac, and passkey (a passkey) to unlock it. See helper/…/Auth.swift.
import { browserName } from './install.js';

const KEY = 'nano.device.v1';

export function loadDevice() {
  try {
    const d = JSON.parse(localStorage.getItem(KEY) || 'null');
    return d && d.dev && d.tok ? d : null;
  } catch {
    return null;
  }
}

export function saveDevice(d) {
  try { localStorage.setItem(KEY, JSON.stringify(d)); } catch {}
}

export function forgetDevice() {
  try {
    localStorage.removeItem(KEY);
    localStorage.removeItem('nano.token'); // the old shared link key
  } catch {}
}

/** What the Mac lists this phone as until Tailscale tells it a better name. */
export function deviceName() {
  const ua = navigator.userAgent;
  const base = /iPad/.test(ua) ? 'iPad' : /iPhone/.test(ua) ? 'iPhone' : /Android/.test(ua) ? 'Android phone' : 'Browser';
  return navigator.standalone === false && /iPhone|iPad/.test(ua) ? `${base} (${browserName})` : base;
}

// ───── base64url ─────
export function b64u(buf) {
  const b = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let s = '';
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function unb64u(str) {
  let s = str.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// ───── Passkeys ─────
export async function passkeysAvailable() {
  try {
    return !!window.PublicKeyCredential && window.isSecureContext &&
      await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
  } catch {
    return false;
  }
}

/**
 * Makes a passkey for this Mac. Call it straight from a tap handler (no await before it):
 * Safari only shows passkey in response to a tap.
 */
export function createPasskey(o) {
  return navigator.credentials.create({
    publicKey: {
      rp: { id: o.rpId, name: 'Duo Mac' },
      user: { id: unb64u(o.userId), name: o.userName, displayName: o.userName },
      challenge: unb64u(o.challenge),
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      authenticatorSelection: { authenticatorAttachment: 'platform', userVerification: 'required', residentKey: 'preferred' },
      attestation: 'none',
      timeout: 90000,
    },
  }).then((cred) => {
    const r = cred.response;
    let authData = r.getAuthenticatorData ? new Uint8Array(r.getAuthenticatorData()) : null;
    let pub = r.getPublicKey ? r.getPublicKey() : null;
    let fmt = 'spki';
    if (!authData || !pub) {
      // Older WebKit: dig both out of the attestation object.
      authData = cbor(new Uint8Array(r.attestationObject)).authData;
      pub = coseToRaw(authData);
      fmt = 'raw';
    }
    return { id: b64u(cred.rawId), clientData: b64u(r.clientDataJSON), authData: b64u(authData), pub: b64u(pub), fmt };
  });
}

/** passkey for one challenge. Call it straight from a tap handler, like createPasskey. */
export function getAssertion(o) {
  return navigator.credentials.get({
    publicKey: {
      challenge: unb64u(o.challenge),
      rpId: o.rpId,
      allowCredentials: [{ type: 'public-key', id: unb64u(o.cred), transports: ['internal', 'hybrid'] }],
      userVerification: 'required',
      timeout: 90000,
    },
  }).then((cred) => ({
    id: b64u(cred.rawId),
    authData: b64u(cred.response.authenticatorData),
    clientData: b64u(cred.response.clientDataJSON),
    sig: b64u(cred.response.signature),
  }));
}

// ───── Minimal CBOR (only for the fallback above) ─────
function cbor(bytes) {
  let i = 0;
  const len = (info) => {
    if (info < 24) return info;
    let n = 0;
    const size = info === 24 ? 1 : info === 25 ? 2 : info === 26 ? 4 : 8;
    for (let k = 0; k < size; k++) n = n * 256 + bytes[i++];
    return n;
  };
  const item = () => {
    const b = bytes[i++], major = b >> 5, n = len(b & 31);
    switch (major) {
      case 0: return n;
      case 1: return -1 - n;
      case 2: { const v = bytes.slice(i, i + n); i += n; return v; }
      case 3: { const v = new TextDecoder().decode(bytes.slice(i, i + n)); i += n; return v; }
      case 4: { const a = []; for (let k = 0; k < n; k++) a.push(item()); return a; }
      case 5: { const m = {}; for (let k = 0; k < n; k++) { const key = item(); m[key] = item(); } return m; }
      default: return n === 20 ? false : n === 21 ? true : null;
    }
  };
  return item();
}

/** P-256 key from the authenticator data's COSE key, as raw x‖y. */
function coseToRaw(authData) {
  const credLen = (authData[53] << 8) | authData[54];
  const key = cbor(authData.slice(55 + credLen));
  const raw = new Uint8Array(64);
  raw.set(key[-2], 0);
  raw.set(key[-3], 32);
  return raw;
}
