/*
 * Copyright (c) NVIDIA
 *
 * Licensed under the Apache License Version 2.0 with LLVM Exceptions
 * (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 *   https://llvm.org/LICENSE.txt
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include <execution.hpp>
#include <type_traits>

#include "common.cuh"

namespace example::cuda::stream {

namespace then {

template <class Fun, class... As>
  __launch_bounds__(1) 
  __global__ void kernel(Fun fn, As... as) {
    fn(as...);
  }

template <class Fun, class ResultT, class... As>
  __launch_bounds__(1) 
  __global__ void kernel_with_result(Fun fn, ResultT* result, As... as) {
    *result = fn(as...);
  }

template <class ReceiverId, class Fun>
  class receiver_t : receiver_base_t {
    using Receiver = std::__t<ReceiverId>;

    Fun f_;
    operation_state_base_t<ReceiverId> &op_state_;

   public:

    template <class... As _NVCXX_CAPTURE_PACK(As)>
    friend void tag_invoke(std::execution::set_value_t, receiver_t&& self, As&&... as) 
      noexcept requires std::__callable<Fun, As...> {
      _NVCXX_EXPAND_PACK(As, as,
        using result_t = std::decay_t<std::invoke_result_t<Fun, std::decay_t<As>...>>;

        cudaStream_t stream = self.op_state_.stream_;

        if constexpr (std::is_same_v<void, result_t>) {
          kernel<Fun, std::decay_t<As>...><<<1, 1, 0, stream>>>(self.f_, as...);
          self.op_state_.propagate_completion_signal(std::execution::set_value);
        } else {
          result_t *d_result{};
          cudaMallocAsync(&d_result, sizeof(result_t), stream);
          kernel_with_result<Fun, std::decay_t<As>...><<<1, 1, 0, stream>>>(self.f_, d_result, as...);

          // TODO References in completion signature 
          result_t h_result;
          cudaMemcpy(&h_result, d_result, sizeof(result_t), cudaMemcpyDeviceToHost);
          self.op_state_.propagate_completion_signal(std::execution::set_value, h_result);
          cudaFreeAsync(d_result, stream);
        }
      );
    }

    template <std::__one_of<std::execution::set_error_t, 
                            std::execution::set_stopped_t> Tag, class... As>
    friend void tag_invoke(Tag tag, receiver_t&& self, As&&... as) noexcept {
      self.op_state_.propagate_completion_signal(tag, (As&&)as...);
    }

    friend std::execution::env_of_t<Receiver> tag_invoke(std::execution::get_env_t, const receiver_t& self) {
      return std::execution::get_env(self.op_state_.receiver_);
    }

    explicit receiver_t(Fun fun, operation_state_base_t<ReceiverId> &op_state)
      : f_((Fun&&) fun)
      , op_state_(op_state)
    {}
  };

}

template <class SenderId, class FunId>
  struct then_sender_t : sender_base_t {
    using Sender = std::__t<SenderId>;
    using Fun = std::__t<FunId>;

    Sender sndr_;
    Fun fun_;

    using set_error_t = 
      std::execution::completion_signatures<
        std::execution::set_error_t(std::exception_ptr)>;

    template <class Receiver>
      using receiver_t = then::receiver_t<std::__x<Receiver>, Fun>;

    template <class Self, class Env>
      using completion_signatures =
        std::execution::__make_completion_signatures<
          std::__member_t<Self, Sender>,
          Env,
          std::execution::__with_error_invoke_t<
            std::execution::set_value_t, 
            Fun, 
            std::__member_t<Self, Sender>, 
            Env>,
          std::__mbind_front_q<std::execution::__set_value_invoke_t, Fun>>;

    template <std::__decays_to<then_sender_t> Self, std::execution::receiver Receiver>
      requires std::execution::receiver_of<Receiver, completion_signatures<Self, std::execution::env_of_t<Receiver>>>
    friend auto tag_invoke(std::execution::connect_t, Self&& self, Receiver&& rcvr)
      -> stream_op_state_t<std::__member_t<Self, Sender>, receiver_t<Receiver>, Receiver> {
        return stream_op_state<std::__member_t<Self, Sender>>(
          ((Self&&)self).sndr_, 
          (Receiver&&)rcvr,
          [&](operation_state_base_t<std::__x<Receiver>>& stream_provider) -> receiver_t<Receiver> {
            return receiver_t<Receiver>(self.fun_, stream_provider);
          });
    }

    template <std::__decays_to<then_sender_t> Self, class Env>
    friend auto tag_invoke(std::execution::get_completion_signatures_t, Self&&, Env)
      -> std::execution::dependent_completion_signatures<Env>;

    template <std::__decays_to<then_sender_t> Self, class Env>
    friend auto tag_invoke(std::execution::get_completion_signatures_t, Self&&, Env)
      -> completion_signatures<Self, Env> requires true;

    template <std::execution::tag_category<std::execution::forwarding_sender_query> Tag, class... As>
      requires std::__callable<Tag, const Sender&, As...>
    friend auto tag_invoke(Tag tag, const then_sender_t& self, As&&... as)
      noexcept(std::__nothrow_callable<Tag, const Sender&, As...>)
      -> std::__call_result_if_t<std::execution::tag_category<Tag, std::execution::forwarding_sender_query>, Tag, const Sender&, As...> {
      return ((Tag&&) tag)(self.sndr_, (As&&) as...);
    }
  };

}
