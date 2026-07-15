import { forwardRef } from "react";
import type { ButtonHTMLAttributes, PropsWithChildren } from "react";
import { cn } from "../../lib/cn";

type ButtonProps = PropsWithChildren<
  ButtonHTMLAttributes<HTMLButtonElement> & {
    variant?: "default" | "secondary" | "ghost" | "danger";
    size?: "sm" | "md" | "icon";
  }
>;

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { className, variant = "default", size = "md", children, ...props },
  ref,
) {
  return (
    <button
      ref={ref}
      className={cn(
        "maat-button",
        `maat-button--${variant}`,
        `maat-button--${size}`,
        className,
      )}
      {...props}
    >
      {children}
    </button>
  );
});
