import { create } from "zustand";

// Promise-based in-app dialogs that replace window.prompt/window.confirm. WKWebView on macOS
// implements none of the WKUIDelegate JS-panel callbacks, so those native dialogs silently no-op
// there; an in-app modal also fits the app's custom chrome better than a native panel would.

export type ConfirmDialogOptions = {
  title: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  danger?: boolean;
};

export type PromptDialogOptions = {
  title: string;
  label?: string;
  defaultValue?: string;
  confirmLabel?: string;
  cancelLabel?: string;
};

type DialogRequest =
  | { kind: "confirm"; options: ConfirmDialogOptions; resolve: (value: boolean) => void }
  | { kind: "prompt"; options: PromptDialogOptions; resolve: (value: string | null) => void };

type DialogStore = {
  request: DialogRequest | null;
  open: (request: DialogRequest) => void;
  close: () => void;
};

export const useDialogStore = create<DialogStore>((set) => ({
  request: null,
  open: (request) => set({ request }),
  close: () => set({ request: null }),
}));

export function confirmDialog(options: ConfirmDialogOptions): Promise<boolean> {
  return new Promise((resolve) => {
    useDialogStore.getState().open({ kind: "confirm", options, resolve });
  });
}

export function promptDialog(options: PromptDialogOptions): Promise<string | null> {
  return new Promise((resolve) => {
    useDialogStore.getState().open({ kind: "prompt", options, resolve });
  });
}
