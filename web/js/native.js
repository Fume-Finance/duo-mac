// When Duo Mac runs as the iPhone app (ios/), its native side: real haptics, Face ID through the
// Secure Enclave, keeping the screen awake, finding the Mac on this iPhone's hotspot. null in Safari.
export const native = window.duoNative || null;
