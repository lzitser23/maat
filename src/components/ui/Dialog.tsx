import { useEffect, useRef, useState } from "react";
import type { KeyboardEvent, MouseEvent } from "react";
import { Button } from "./Button";
import { useDialogStore } from "../../lib/dialog";

// Single dialog host rendered once near the app root. Backs confirmDialog()/promptDialog() from
// src/lib/dialog.ts — call sites stay imperative (`if (!(await confirmDialog({ ... }))) return;`)
// while this component owns the actual modal.
export function DialogHost() {
  const request = useDialogStore((state) => state.request);
  const close = useDialogStore((state) => state.close);
  const [draft, setDraft] = useState("");
  const inputRef = useRef<HTMLInputElement | null>(null);
  const cancelRef = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    if (!request) return;
    if (request.kind === "prompt") {
      setDraft(request.options.defaultValue ?? "");
      const frame = requestAnimationFrame(() => {
        inputRef.current?.focus();
        inputRef.current?.select();
      });
      return () => cancelAnimationFrame(frame);
    }
    const frame = requestAnimationFrame(() => cancelRef.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [request]);

  if (!request) return null;

  const cancel = () => {
    if (request.kind === "confirm") request.resolve(false);
    else request.resolve(null);
    close();
  };

  const confirm = () => {
    if (request.kind === "confirm") {
      request.resolve(true);
    } else {
      if (!draft.trim()) return;
      request.resolve(draft);
    }
    close();
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    event.stopPropagation();
    if (event.key === "Escape") {
      event.preventDefault();
      cancel();
    } else if (event.key === "Enter") {
      event.preventDefault();
      confirm();
    }
  };

  const stopClick = (event: MouseEvent<HTMLDivElement>) => event.stopPropagation();

  const danger = request.kind === "confirm" && request.options.danger;

  return (
    <div
      className="fixed inset-0 z-[100] flex items-center justify-center bg-black/50 backdrop-blur-sm"
      onMouseDown={cancel}
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="maat-dialog-title"
        onMouseDown={stopClick}
        onKeyDown={handleKeyDown}
        className="w-[360px] rounded-xl border border-[var(--line)] bg-[var(--panel-strong)] p-5 shadow-[var(--shadow-soft)]"
      >
        <h2 id="maat-dialog-title" className="text-sm font-semibold text-[var(--fg)]">
          {request.options.title}
        </h2>

        {request.kind === "confirm" ? (
          <p className="mt-2 text-sm text-[var(--muted)]">{request.options.message}</p>
        ) : (
          <div className="mt-3">
            {request.options.label && (
              <label htmlFor="maat-dialog-input" className="mb-1.5 block text-xs font-medium text-[var(--muted)]">
                {request.options.label}
              </label>
            )}
            <input
              id="maat-dialog-input"
              ref={inputRef}
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              className="w-full rounded-md border border-[var(--line)] bg-[var(--panel)] px-3 py-2 text-sm text-[var(--fg)] outline-none focus-visible:ring-1 focus-visible:ring-[var(--focus)]"
            />
          </div>
        )}

        <div className="mt-4 flex justify-end gap-2">
          <Button ref={cancelRef} variant="secondary" size="sm" onClick={cancel}>
            {request.options.cancelLabel ?? "Cancel"}
          </Button>
          <Button
            variant={danger ? "danger" : "default"}
            size="sm"
            onClick={confirm}
            disabled={request.kind === "prompt" && !draft.trim()}
          >
            {request.options.confirmLabel ?? (request.kind === "confirm" ? "Confirm" : "Create")}
          </Button>
        </div>
      </div>
    </div>
  );
}
