#include <catch2/catch.hpp>
#include <execution.hpp>

#include "../examples/schedulers/inline_scheduler.hpp"
#include "schedulers/stream.cuh"
#include "common.cuh"

namespace ex = std::execution;
namespace stream = example::cuda::stream;

using example::cuda::is_on_gpu;

TEST_CASE("transfer to stream context returns a sender", "[cuda][stream][adaptors][transfer]") {
  stream::context_t stream_context{};
  example::inline_scheduler cpu{};
  stream::scheduler_t gpu = stream_context.get_scheduler();

  auto snd = ex::schedule(cpu) | ex::transfer(gpu);
  STATIC_REQUIRE(ex::sender<decltype(snd)>);
  (void)snd;
}

TEST_CASE("transfer from stream context returns a sender", "[cuda][stream][adaptors][transfer]") {
  stream::context_t stream_context{};

  example::inline_scheduler cpu{};
  stream::scheduler_t gpu = stream_context.get_scheduler();

  auto snd = ex::schedule(gpu) | ex::transfer(cpu);
  STATIC_REQUIRE(ex::sender<decltype(snd)>);
  (void)snd;
}

TEST_CASE("transfer changes context to GPU", "[cuda][stream][adaptors][transfer]") {
  stream::context_t stream_context{};

  example::inline_scheduler cpu{};
  stream::scheduler_t gpu = stream_context.get_scheduler();

  auto snd = ex::schedule(cpu) //
           | ex::then([=] { 
               if (!is_on_gpu()) {
                 return 1;
               }
               return 0;
             })
           | ex::transfer(gpu)
           | ex::then([=](int val) -> int {
               if (is_on_gpu() && val == 1) {
                 return 2;
               }
               return 0;
             });
  const auto [result] = std::this_thread::sync_wait(std::move(snd)).value();

  REQUIRE(result == 2);
}

TEST_CASE("transfer changes context from GPU", "[cuda][stream][adaptors][transfer]") {
  stream::context_t stream_context{};

  example::inline_scheduler cpu{};
  stream::scheduler_t gpu = stream_context.get_scheduler();

  auto snd = ex::schedule(gpu) //
           | ex::then([=] { 
               if (is_on_gpu()) {
                 return 1;
               }
               return 0;
             })
           | ex::transfer(cpu)
           | ex::then([=](int val) -> int {
               if (!is_on_gpu() && val == 1) {
                 return 2;
               }
               return 0;
             });
  const auto [result] = std::this_thread::sync_wait(std::move(snd)).value();

  REQUIRE(result == 2);
}

