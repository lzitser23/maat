#pragma once
// Minimal Microsoft::WRL::ComPtr<> + Callback<> shim.
//
// Zig's bundled mingw-w64 headers ship a stub <wrl.h> that lacks the real
// Windows SDK's Callback<>/ComPtr<> machinery -- the real implementation
// pulls in the full WinRT/activation header stack (roapi.h, inspectable.h,
// WinString.h, weakreference.h, ...) which mingw doesn't bundle either.
// webview2_host.cpp (see the two `using Microsoft::WRL::...` lines) only
// uses two small, well-defined pieces of WRL:
//   - ComPtr<T>: a ref-counted COM smart pointer.
//   - Callback<T>(lambda): wraps a lambda as a heap-allocated, ref-counted
//     implementation of a single-method COM completion-handler interface T
//     (every *CompletedHandler / *EventHandler interface WebView2.h
//     declares is IUnknown + exactly one pure-virtual Invoke(...)).
// This header reimplements just those two pieces against plain <unknwn.h>,
// matching the real Microsoft::WRL API surface closely enough for
// webview2_host.cpp to compile and run unmodified. It intentionally does
// not implement RuntimeClass/Implements/Module -- nothing in this app uses
// them.

#include <unknwn.h>
#include <atomic>
#include <utility>

namespace Microsoft {
namespace WRL {

template <typename T>
class ComPtr {
public:
    ComPtr() noexcept : ptr_(nullptr) {}
    ComPtr(std::nullptr_t) noexcept : ptr_(nullptr) {}
    ComPtr(T *p) noexcept : ptr_(p) {
        if (ptr_) ptr_->AddRef();
    }
    ComPtr(const ComPtr &other) noexcept : ptr_(other.ptr_) {
        if (ptr_) ptr_->AddRef();
    }
    ComPtr(ComPtr &&other) noexcept : ptr_(other.ptr_) {
        other.ptr_ = nullptr;
    }
    ~ComPtr() {
        if (ptr_) ptr_->Release();
    }

    ComPtr &operator=(const ComPtr &other) noexcept {
        if (this != &other) {
            T *old = ptr_;
            ptr_ = other.ptr_;
            if (ptr_) ptr_->AddRef();
            if (old) old->Release();
        }
        return *this;
    }
    ComPtr &operator=(ComPtr &&other) noexcept {
        if (this != &other) {
            if (ptr_) ptr_->Release();
            ptr_ = other.ptr_;
            other.ptr_ = nullptr;
        }
        return *this;
    }
    ComPtr &operator=(T *p) noexcept {
        if (p) p->AddRef();
        if (ptr_) ptr_->Release();
        ptr_ = p;
        return *this;
    }

    T *Get() const noexcept { return ptr_; }
    T *operator->() const noexcept { return ptr_; }
    operator T *() const noexcept { return ptr_; }
    explicit operator bool() const noexcept { return ptr_ != nullptr; }
    T **GetAddressOf() noexcept { return &ptr_; }
    // Real WRL::ComPtr returns a proxy object here (so `&ptr` also converts
    // to IUnknown**/void** for QueryInterface-style calls); this app only
    // ever takes the address to fill in a same-typed out-param, so a plain
    // T** is enough.
    T **operator&() noexcept { return GetAddressOf(); }
    T **ReleaseAndGetAddressOf() noexcept {
        if (ptr_) {
            ptr_->Release();
            ptr_ = nullptr;
        }
        return &ptr_;
    }
    void Reset() noexcept {
        if (ptr_) {
            ptr_->Release();
            ptr_ = nullptr;
        }
    }
    T *Detach() noexcept {
        T *tmp = ptr_;
        ptr_ = nullptr;
        return tmp;
    }
    // Takes ownership of a raw pointer the caller already holds a
    // reference to, without an extra AddRef (mirrors the real ComPtr).
    void Attach(T *p) noexcept {
        if (ptr_) ptr_->Release();
        ptr_ = p;
    }

private:
    T *ptr_;
};

namespace detail {

// Deduces the argument list of TIface::Invoke from its pointer-to-member
// type so CallbackImpl can declare an override with a matching signature
// without hardcoding it per interface.
template <typename M>
struct InvokeSignature;

template <typename C, typename... Args>
struct InvokeSignature<HRESULT(STDMETHODCALLTYPE C::*)(Args...)> {
    template <typename Fn>
    class Impl : public C {
    public:
        explicit Impl(Fn fn) : fn_(std::move(fn)) {}

        // Deliberately permissive: always hands back this object regardless
        // of the requested IID. These are private, single-use glue objects
        // WebView2 calls exactly once (Invoke) and then releases -- nothing
        // in this app ever queries them for a different interface.
        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID /*riid*/, void **out) override {
            if (!out) return E_POINTER;
            *out = static_cast<C *>(this);
            AddRef();
            return S_OK;
        }
        ULONG STDMETHODCALLTYPE AddRef() override {
            return static_cast<ULONG>(++ref_);
        }
        ULONG STDMETHODCALLTYPE Release() override {
            unsigned long remaining = --ref_;
            if (remaining == 0) delete this;
            return static_cast<ULONG>(remaining);
        }
        HRESULT STDMETHODCALLTYPE Invoke(Args... args) override {
            return fn_(args...);
        }

    private:
        std::atomic<unsigned long> ref_{1};
        Fn fn_;
    };
};

} // namespace detail

// Mirrors Microsoft::WRL::Callback<TIface>(fn): heap-allocates a ref-
// counted TIface implementation that forwards Invoke(...) to fn, returned
// pre-wrapped in a ComPtr the same way the real helper does.
template <typename TIface, typename Fn>
ComPtr<TIface> Callback(Fn fn) {
    using Impl = typename detail::InvokeSignature<decltype(&TIface::Invoke)>::template Impl<Fn>;
    return ComPtr<TIface>(new Impl(std::move(fn)));
}

} // namespace WRL
} // namespace Microsoft
