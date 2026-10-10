#pragma once
#include <pthread.h>
#include <utility>
#include <tuple>
#include <stdexcept>

namespace wowee::core {

class ThreadWithStack {
public:
    ThreadWithStack() = default;

    template <typename Function, typename... Args>
    explicit ThreadWithStack(size_t stackSize, Function&& f, Args&&... args) {
        auto task = new auto([f = std::forward<Function>(f), 
                              args = std::make_tuple(std::forward<Args>(args)...)]() mutable {
            std::apply(f, args);
        });

        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, stackSize);

        int rc = pthread_create(&handle_, &attr, [](void* arg) -> void* {
            auto fn = reinterpret_cast<decltype(task)>(arg);
            (*fn)();
            delete fn;
            return nullptr;
        }, task);

        pthread_attr_destroy(&attr);
        if (rc == 0) {
            joinable_ = true;
        } else {
            delete task;
            throw std::runtime_error("Failed to create thread with stack");
        }
    }

    ~ThreadWithStack() {
        if (joinable_) {
            pthread_detach(handle_);
        }
    }

    ThreadWithStack(ThreadWithStack&& other) noexcept 
        : handle_(other.handle_), joinable_(other.joinable_) {
        other.joinable_ = false;
    }

    ThreadWithStack& operator=(ThreadWithStack&& other) noexcept {
        if (this != &other) {
            if (joinable_) pthread_detach(handle_);
            handle_ = other.handle_;
            joinable_ = other.joinable_;
            other.joinable_ = false;
        }
        return *this;
    }

    ThreadWithStack(const ThreadWithStack&) = delete;
    ThreadWithStack& operator=(const ThreadWithStack&) = delete;

    bool joinable() const { return joinable_; }

    void join() {
        if (joinable_) {
            pthread_join(handle_, nullptr);
            joinable_ = false;
        }
    }

private:
    pthread_t handle_{};
    bool joinable_ = false;
};

} // namespace wowee::core
