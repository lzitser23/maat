// Minimal ambient type declaration for the Native SDK's `window.zero` bridge.
// Trimmed down from @native-sdk/cli's native-sdk.d.ts to just the surface
// src/lib/bridge.ts actually calls. The SDK package itself is never imported
// at runtime -- this only exists so bridge.ts type-checks against window.zero.

export type NativeSdkJson = null | boolean | number | string | NativeSdkJson[] | { [key: string]: NativeSdkJson };

export type NativeSdkErrorCode =
  | "invalid_request"
  | "unknown_command"
  | "permission_denied"
  | "handler_failed"
  | "payload_too_large"
  | "internal_error"
  | string;

export interface NativeSdkInvokeError extends Error {
  code: NativeSdkErrorCode;
}

export interface NativeSdkFileDropDetail {
  windowId: number;
  paths: string[];
}

export interface NativeSdkApi {
  invoke<T = NativeSdkJson>(command: string, payload?: NativeSdkJson): Promise<T>;
  on(name: "drop:files", callback: (detail: NativeSdkFileDropDetail) => void): () => void;
  on<T = NativeSdkJson>(name: string, callback: (detail: T) => void): () => void;
  off(name: "drop:files", callback: (detail: NativeSdkFileDropDetail) => void): void;
  off<T = NativeSdkJson>(name: string, callback: (detail: T) => void): void;
}

declare global {
  interface Window {
    zero?: NativeSdkApi;
  }
}

export {};
