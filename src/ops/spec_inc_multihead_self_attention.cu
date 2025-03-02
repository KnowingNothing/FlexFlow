/* Copyright 2023 CMU, Facebook, LANL, MIT, NVIDIA, and Stanford (alphabetical)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#if defined(FF_USE_CUDA) || defined(FF_USE_HIP_CUDA)
#include "cuComplex.h"
#endif
#include "flexflow/ffconst_utils.h"
#include "flexflow/ops/kernels/inc_multihead_self_attention_kernels.h"
#include "flexflow/ops/kernels/inc_multihead_self_attention_utils.cuh"
#include "flexflow/ops/spec_inc_multihead_self_attention.h"
#include "flexflow/utils/cuda_helper.h"

namespace FlexFlow {

// declare Legion names
using Legion::coord_t;
using Legion::Memory;
using namespace Kernels::IncMultiHeadAttention;

namespace Kernels {
namespace SpecIncMultiHeadAttention {

template <typename DT>
__global__ void spec_store_kv_cache(
    DT const *devQKVProjArray,
    DT *kCache_ptr,
    DT *vCache_ptr,
    BatchConfig::PerTokenInfo *tokenInfos,
    BatchConfig::PerRequestInfo *requestInfo,
    BeamSearchBatchConfig::BeamSearchPerTokenInfo *beamTokenInfos,
    BeamSearchBatchConfig::BeamSearchPerRequestInfo *beamRequestInfos,
    int qProjSize,
    int kProjSize,
    int vProjSize,
    int num_tokens,
    int max_seq_len,
    int max_beam_width,
    bool is_root,
    int hidden_size) {
  CUDA_KERNEL_LOOP(i, num_tokens * hidden_size * 2) {
    int token_idx = i / (hidden_size * KV_WEIGHT_NUM);
    int offset = i % hidden_size;

    size_t val_idx =
        token_idx * QKV_WEIGHT_NUM * hidden_size + hidden_size + offset;

    DT kVal = devQKVProjArray[val_idx];
    DT vVal = devQKVProjArray[val_idx + hidden_size];

    // above no need to be changed
    // int const req_id = id_map[token_idx].request_index;
    // int const tok_id = id_map[token_idx].token_position;
    // int const sub_req_id = id_map[token_idx].sub_request_index;
    // int const parent_id = id_map[token_idx].parent_id;
    // int const beam_depth = id_map[token_idx].beam_depth;
    // int const beam_width = id_map[token_idx].beam_width;

    int const req_id = tokenInfos[token_idx].request_index;
    int const tok_id = tokenInfos[token_idx].abs_depth_in_request;
    int const sub_req_id = beamTokenInfos[token_idx].sub_request_index;
    int const parent_id = beamRequestInfos[req_id].parent_id[sub_req_id];
    int const beam_depth = beamRequestInfos[req_id].current_depth;
    int const beam_width = beamRequestInfos[req_id].beam_size;

    kCache_ptr[(req_id * max_beam_width + sub_req_id) *
                   (hidden_size * max_seq_len) +
               tok_id * hidden_size + offset] = kVal;
    vCache_ptr[(req_id * max_beam_width + sub_req_id) *
                   (hidden_size * max_seq_len) +
               tok_id * hidden_size + offset] = vVal;

    // replica in the root iteration
    if (beam_depth == 1) {
      for (int i = 1; i < beam_width; i++) {
        kCache_ptr[(req_id * max_beam_width + i) * (hidden_size * max_seq_len) +
                   tok_id * hidden_size + offset] = kVal;
        vCache_ptr[(req_id * max_beam_width + i) * (hidden_size * max_seq_len) +
                   tok_id * hidden_size + offset] = vVal;
      }
    }

    // if (head_idx == 0 && beam_depth == 0 && token_idx == 8 && k_cache) {
    //   // printf("token idx %d\n", token_idx);
    //   printf("data idx: %d, tok_id %d, new_token_cache_idx %d, parent_id %d,
    //   "
    //          "sub_req_id %d, num_tokens %d, kProjSize %d, num_kv_heads %d,
    //          val "
    //          "%f, beam_width %d\n",
    //          data_idx,
    //          tok_id,
    //          new_token_cache_idx,
    //          parent_id,
    //          sub_req_id,
    //          num_tokens,
    //          kProjSize,
    //          num_kv_heads,
    //          val,
    //          beam_width);
    // }

    // naive cache stealing
    if (sub_req_id != parent_id) {
      if (offset == 0 && tok_id == 0) {
        printf("cache stealing!, depth %d req_id %d sub_req_id %d, parentid "
               "%d, tok_id %d\n",
               beam_depth,
               req_id,
               sub_req_id,
               parent_id,
               tok_id);
      }

      for (int depth = 0; depth < beam_depth; depth++) {
        int steal_token_idx = tok_id - beam_depth + depth;
        int steal_from_idx = (req_id * max_beam_width + parent_id) *
                                 (hidden_size * max_seq_len) +
                             steal_token_idx * hidden_size + offset;
        int steal_to_idx = (req_id * max_beam_width + sub_req_id) *
                               (hidden_size * max_seq_len) +
                           steal_token_idx * hidden_size + offset;
        kCache_ptr[steal_to_idx] = kCache_ptr[steal_from_idx];
        vCache_ptr[steal_to_idx] = vCache_ptr[steal_from_idx];

        //   if(data_idx == 0 && head_idx == 0 && k_cache && req_id == 1){
        //     printf("cache stealing kernel!, steal_token_idx %d\n",
        //     steal_token_idx);
        // }
      }
    }

    // parallel cache stealing not yet implemented
    // logic shld be
    // launch spec_store_kv_cache with parallelism * current depth
    // from the i here, get depth index
    // if depth index not the current one, check if we need to steal
    // steal if needed

    // cache stealing theory
    // identify which sub request does this token come from
    // for initial token, 0
    // for other, may 0,0,1/ 0,1,2/ 1,1,1 to get which cache to be reuse and
    // which to be delete copy beam_size bunch of blocks when sub_req_id ==
    // parent_id : like 0 -> 0, 1->1, 2->2, do nothing, just append the new k/v
  }
}

template <typename DT>
void update_kv_cache_kernel(SpecIncMultiHeadSelfAttentionMeta const *m,
                            BeamSearchBatchConfig const *bc,
                            cudaStream_t stream) {
  int num_tokens = bc->num_active_tokens();
  int curr_depth = bc->beamRequestsInfo[0].current_depth;
  // printf("curr depth: %d\n", curr_depth);
  // assert(curr_depth < 3);
  if (num_tokens > 0) {
    int parallelism = m->hidden_size * KV_WEIGHT_NUM * num_tokens;
    spec_store_kv_cache<<<GET_BLOCKS(parallelism),
                          min(CUDA_NUM_THREADS, parallelism),
                          0,
                          stream>>>(static_cast<DT *>(m->devQKVProjArray),
                                    static_cast<DT *>(m->keyCache),
                                    static_cast<DT *>(m->valueCache),
                                    m->token_infos,
                                    m->request_infos,
                                    m->beam_token_infos,
                                    m->beam_request_infos,
                                    m->qProjSize,
                                    m->kProjSize,
                                    m->vProjSize,
                                    num_tokens,
                                    BatchConfig::max_sequence_length(),
                                    BeamSearchBatchConfig::MAX_BEAM_WIDTH,
                                    /*root*/ curr_depth == 0,
                                    m->hidden_size);
  }
}

template <typename DT>
__global__ void spec_fill_entries_above_diagonal(DT *matrix,
                                                 size_t new_tokens,
                                                 size_t total_tokens_in_request,
                                                 size_t num_q_heads,
                                                 DT value) {
  CUDA_KERNEL_LOOP(i, new_tokens * total_tokens_in_request * num_q_heads) {
    // size_t head_idx = i / (new_tokens * total_tokens_in_request);
    size_t src_idx = (i / new_tokens) % total_tokens_in_request;
    size_t dst_idx = i % new_tokens + total_tokens_in_request - new_tokens;
    // Casual Mask
    if (src_idx > dst_idx) {
      matrix[i] = value;
    }
  }
}

template <typename DT>
void compute_attention_kernel_prompt(SpecIncMultiHeadSelfAttentionMeta const *m,
                                     BeamSearchBatchConfig const *bc,
                                     int shard_id,
                                     DT *output_ptr,
                                     DT const *bias_ptr,
                                     DT const *weight_ptr,
                                     cudaStream_t stream) {
  checkCUDA(cublasSetStream(m->handle.blas, stream));
  checkCUDNN(cudnnSetStream(m->handle.dnn, stream));
  cudaDataType_t cublas_data_type = ff_to_cuda_datatype(m->output_type[0]);
  cudnnDataType_t cudnn_data_type = ff_to_cudnn_datatype(m->output_type[0]);
  assert(data_type_size(m->output_type[0]) == sizeof(DT));
#if defined(CUDA_VERSION) && (CUDA_VERSION < 11000)
  cudaDataType_t compute_type = cublas_data_type;
#else
  // For best performance, set the default cublas compute type to
  // CUBLAS_COMPUTE_16F for half precision and to
  // CUBLAS_COMPUTE_32F_FAST_16F for full precision
  cublasComputeType_t compute_type = CUBLAS_COMPUTE_16F;
  if (m->output_type[0] == DT_FLOAT) {
    compute_type = CUBLAS_COMPUTE_32F_FAST_16F;
  }
#endif
  // int num_requests = bc->num_active_requests();
  int num_tokens = bc->num_active_tokens();
  int tokens_previous_requests = 0;
  int tokens_prev_requests_squares = 0;
  // int qkv_block_size =
  //     (m->qProjSize + m->kProjSize + m->vProjSize) * num_tokens;
  int q_block_size = m->qProjSize;

  int kt_block_size = m->kProjSize;
  int kt_req_block_size =
      kt_block_size * m->num_q_heads * BatchConfig::max_sequence_length();
  int vt_block_size = m->vProjSize;
  int vt_req_block_size =
      vt_block_size * m->num_q_heads * BatchConfig::max_sequence_length();
  assert(m->qProjSize == m->kProjSize);

  for (int i = 0; i < bc->max_requests_per_batch(); i++) {
    if (bc->request_completed[i]) {
      continue;
    }
    for (int sub_req_id = 0; sub_req_id < bc->sub_requests[i]; sub_req_id++) {
      // int num_new_tokens = bc->num_processing_tokens[i];
      // int total_tokens = bc->token_last_available_idx[i] + 1;

      int num_new_tokens = bc->requestsInfo[i].num_tokens_in_batch;
      int total_tokens = bc->requestsInfo[i].first_token_depth_in_request +
                         bc->requestsInfo[i].num_tokens_in_batch;

      if (num_new_tokens <= 0) {
        continue;
      }

      // Compute (QK^T/sqrt(d_k))
      int m_ = num_new_tokens;
      int n = total_tokens;
      int k = m->qProjSize;
      int lda = k * m->num_q_heads * QKV_WEIGHT_NUM, ldb = k * m->num_q_heads,
          ldc = m_;
      int strideA = q_block_size;
      int strideB = kt_block_size;
      int strideC = num_new_tokens * total_tokens;

      // a flag of using this scaling alpha
      DT alpha = 1.0f, beta = 0.0f;
      if (*m->qk_prod_scaling) {
        alpha = static_cast<DT>(1.0f / sqrt(m->kProjSize));
      }
      // To get A, skip over Q entries from previous requests (same head)
      DT const *A = static_cast<DT *>(m->devQKVProjArray) +
                    bc->requestsInfo[i].first_token_offset_in_batch *
                        m->qProjSize * m->num_q_heads * QKV_WEIGHT_NUM;
      // To get B, skip over K entries from previous requests (all heads +
      // padding)
      DT const *B = static_cast<DT *>(m->keyCache) +
                    (i * bc->MAX_BEAM_WIDTH + sub_req_id) * kt_req_block_size;

      // if (i == 0 && sub_req_id == 0 &&
      //     bc->beam_slots.at(0).current_depth == 1) {
      //   int offset = (float *)B - m->keyCache;
      //   printf("key cache offset %d\n", kt_req_block_size);
      // }
      // To get C, skip over QK^T products from previous requests
      DT *C = static_cast<DT *>(m->qk_prods) +
              m->num_q_heads * tokens_prev_requests_squares;
      checkCUDA(cublasGemmStridedBatchedEx(m->handle.blas,
                                           CUBLAS_OP_T,
                                           CUBLAS_OP_N,
                                           m_,
                                           n,
                                           k,
                                           &alpha,
                                           A,
                                           cublas_data_type,
                                           lda,
                                           strideA,
                                           B,
                                           cublas_data_type,
                                           ldb,
                                           strideB,
                                           &beta,
                                           C,
                                           cublas_data_type,
                                           ldc,
                                           strideC,
                                           m->num_q_heads,
                                           compute_type,
                                           CUBLAS_GEMM_DEFAULT_TENSOR_OP));
      // add alibi position bias to qk production
      // add alibi position bias to qk production
      if (*m->position_bias) {
        size_t parallelism = m->num_q_heads * total_tokens * num_new_tokens;
        apply_position_bias_qkprd<<<GET_BLOCKS(parallelism),
                                    min((size_t)CUDA_NUM_THREADS, parallelism),
                                    0,
                                    stream>>>(C,
                                              num_new_tokens,
                                              total_tokens,
                                              m->num_q_heads,
                                              m->global_num_q_heads,
                                              shard_id);
      }
      // Fill all elements above diagonal in qk prods with -inf to force
      // causal attention.
      assert(num_new_tokens <= total_tokens);
      if (num_new_tokens > 1) {
        size_t parallelism = m->num_q_heads * num_new_tokens * total_tokens;
        spec_fill_entries_above_diagonal<<<GET_BLOCKS(parallelism),
                                           min((size_t)CUDA_NUM_THREADS,
                                               parallelism),
                                           0,
                                           stream>>>(
            C,
            num_new_tokens,
            total_tokens,
            m->num_q_heads,
            static_cast<DT>(-INFINITY));
      }
      // Compute Softmax(QK^T/sqrt(d_k))
      // Before modifying the parameters below, make sure to read the following
      // description of the CUDNN_TENSOR_NCHW tensor layout, from
      // https://docs.nvidia.com/deeplearning/cudnn/api/index.html#cudnnTensorFormat_t:
      // This tensor format specifies that the data is laid out in the following
      // order: batch size, feature maps, rows, columns. The strides are
      // implicitly defined in such a way that the data are contiguous in memory
      // with no padding between images, feature maps, rows, and columns; the
      // columns are the inner dimension and the images are the outermost
      // dimension.
      int n_param = m->num_q_heads;
      int c_param = total_tokens;
      int h_param = 1;
      int w_param = num_new_tokens;
      checkCUDNN(cudnnSetTensor4dDescriptor(m->qk_tensor,
                                            CUDNN_TENSOR_NCHW,
                                            cudnn_data_type,
                                            n_param,
                                            c_param,
                                            h_param,
                                            w_param));
      float softmax_alpha = 1.0f, softmax_beta = 0.0f;
      DT *C_softmax = static_cast<DT *>(m->qk_prods_softmax) +
                      m->num_q_heads * tokens_prev_requests_squares;
      // The softmax operation below is executed according to the
      // CUDNN_SOFTMAX_MODE_CHANNEL, which is also described in the docs: The
      // softmax operation is computed per spatial location (H,W) per image (N)
      // across dimension C.
      checkCUDNN(cudnnSoftmaxForward(m->handle.dnn,
                                     CUDNN_SOFTMAX_ACCURATE,
                                     CUDNN_SOFTMAX_MODE_CHANNEL,
                                     &softmax_alpha,
                                     m->qk_tensor,
                                     C,
                                     &softmax_beta,
                                     m->qk_tensor,
                                     C_softmax));
      // Matmul softmax(QK^T/sqrt(d_k)) by V
      alpha = 1.0f, beta = 0.0f;
      m_ = m->vProjSize;
      n = num_new_tokens;
      k = total_tokens;
      lda = m_ * m->num_q_heads, ldb = n, ldc = m_ * m->num_q_heads;
      strideA = vt_block_size;
      strideB = num_new_tokens * total_tokens;
      strideC = m->vProjSize;
      // To get A, skip over V^T entries from previous requests (all heads +
      // padding)
      A = static_cast<DT *>(m->valueCache) +
          (i * bc->MAX_BEAM_WIDTH + sub_req_id) * vt_req_block_size;
      // To get B, skip over softmax(QK^T/sqrt(d_k)) entries from previous
      // requests (all heads)
      B = C_softmax;
      // To get C, skip over softmax(QK^T/sqrt(d_k))V products from previous
      // requests
      C = static_cast<DT *>(m->attn_heads) +
          (tokens_previous_requests + bc->num_generation_tokens) *
              m->num_q_heads * m->vProjSize;
      checkCUDA(cublasGemmStridedBatchedEx(m->handle.blas,
                                           CUBLAS_OP_N,
                                           CUBLAS_OP_T,
                                           m_,
                                           n,
                                           k,
                                           &alpha,
                                           A,
                                           cublas_data_type,
                                           lda,
                                           strideA,
                                           B,
                                           cublas_data_type,
                                           ldb,
                                           strideB,
                                           &beta,
                                           C,
                                           cublas_data_type,
                                           ldc,
                                           strideC,
                                           m->num_q_heads,
                                           compute_type,
                                           CUBLAS_GEMM_DEFAULT_TENSOR_OP));

      tokens_previous_requests += num_new_tokens;
      tokens_prev_requests_squares += num_new_tokens * total_tokens;
    }
  }

  // assert(tokens_previous_requests == num_tokens);
}

template <typename DT>
void inference_kernel(SpecIncMultiHeadSelfAttentionMeta const *m,
                      BeamSearchBatchConfig const *bc,
                      int shard_id,
                      DT const *input_ptr,
                      DT const *weight_ptr,
                      DT *output_ptr,
                      DT const *bias_ptr,
                      cudaStream_t stream) {
  // here because we need postion info in infernece 1
  cudaMemcpyAsync(m->token_infos,
                  &(bc->tokensInfo),
                  bc->num_active_tokens() * sizeof(BatchConfig::PerTokenInfo),
                  cudaMemcpyHostToDevice,
                  stream);
  cudaMemcpyAsync(m->request_infos,
                  &(bc->requestsInfo),
                  bc->max_requests_per_batch() *
                      sizeof(BatchConfig::PerRequestInfo),
                  cudaMemcpyHostToDevice,
                  stream);
  cudaMemcpyAsync(m->beam_token_infos,
                  &(bc->beamTokenInfo),
                  bc->num_active_tokens() * bc->MAX_BEAM_WIDTH *
                      sizeof(BeamSearchBatchConfig::BeamSearchPerTokenInfo),
                  cudaMemcpyHostToDevice,
                  stream);
  cudaMemcpyAsync(m->beam_request_infos,
                  &(bc->beamRequestsInfo),
                  bc->max_requests_per_batch() *
                      sizeof(BeamSearchBatchConfig::BeamSearchPerRequestInfo),
                  cudaMemcpyHostToDevice,
                  stream);
  // phase 1: Implement kernel to compute KQV for input tokens
  compute_qkv_kernel(m,
                     bc,
                     shard_id,
                     input_ptr,
                     weight_ptr,
                     static_cast<DT *>(m->devQKVProjArray),
                     bias_ptr,
                     stream);
  // phase 2: Update key/val cache
  update_kv_cache_kernel<DT>(m, bc, stream);
  if (bc->num_generation_tokens > 0) {
    compute_attention_kernel_generation<DT>(
        m, bc, static_cast<DT *>(m->attn_heads), stream);
  }
  // phase 3: Compute attention score
  // 3 kernels for pahse 3: matmul1 - softmax - matmal2
  if (bc->num_tokens > bc->num_generation_tokens) {
    compute_attention_kernel_prompt(
        m, bc, shard_id, output_ptr, bias_ptr, weight_ptr, stream);
  }

  // compute output production and bias together for all tokens
  int num_tokens =
      bc->num_active_tokens() * BeamSearchBatchConfig::MAX_BEAM_WIDTH;
        
  compute_o_prod_bias(
      m, bc, shard_id, output_ptr, weight_ptr, bias_ptr, num_tokens, stream);
}

} // namespace SpecIncMultiHeadAttention
} // namespace Kernels

/*static*/
void SpecIncMultiHeadSelfAttention::inference_kernel_wrapper(
    SpecIncMultiHeadSelfAttentionMeta const *m,
    BeamSearchBatchConfig const *bc,
    int shard_id,
    GenericTensorAccessorR const &input,
    GenericTensorAccessorR const &weight,
    GenericTensorAccessorW const &output,
    GenericTensorAccessorR const &bias) {
  cudaStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  bool use_bias = *m->qkv_bias || *m->final_bias;

  cudaEvent_t t_start, t_end;
  if (m->profiling) {
    cudaEventCreate(&t_start);
    cudaEventCreate(&t_end);
    cudaEventRecord(t_start, stream);
  }

  assert(input.data_type == weight.data_type);
  assert(input.data_type == output.data_type);
  if (use_bias) {
    assert(input.data_type == bias.data_type);
  }

  if (input.data_type == DT_HALF) {
    half const *bias_ptr =
        use_bias ? bias.get_half_ptr() : static_cast<half const *>(nullptr);
    Kernels::SpecIncMultiHeadAttention::inference_kernel(m,
                                                         bc,
                                                         shard_id,
                                                         input.get_half_ptr(),
                                                         weight.get_half_ptr(),
                                                         output.get_half_ptr(),
                                                         bias_ptr,
                                                         stream);
  } else if (input.data_type == DT_FLOAT) {
    float const *bias_ptr =
        use_bias ? bias.get_float_ptr() : static_cast<float const *>(nullptr);
    Kernels::SpecIncMultiHeadAttention::inference_kernel(m,
                                                         bc,
                                                         shard_id,
                                                         input.get_float_ptr(),
                                                         weight.get_float_ptr(),
                                                         output.get_float_ptr(),
                                                         bias_ptr,
                                                         stream);
  } else {
    assert(false && "Unspported data type");
  }

  if (m->profiling) {
    cudaEventRecord(t_end, stream);
    checkCUDA(cudaEventSynchronize(t_end));
    float elapsed = 0;
    checkCUDA(cudaEventElapsedTime(&elapsed, t_start, t_end));
    cudaEventDestroy(t_start);
    cudaEventDestroy(t_end);
    printf("SpecIncMultiHeadSelfAttention forward time = %.2fms\n", elapsed);
    // print_tensor<3, float>(acc_query.ptr, acc_query.rect,
    // "[Attention:forward:query]"); print_tensor<3, float>(acc_output.ptr,
    // acc_output.rect, "[Attention:forward:output]");
  }
}

SpecIncMultiHeadSelfAttentionMeta::SpecIncMultiHeadSelfAttentionMeta(
    FFHandler handler,
    SpecIncMultiHeadSelfAttention const *attn,
    GenericTensorAccessorR const &weight,
    MemoryAllocator &gpu_mem_allocator,
    int num_samples,
    int _num_q_heads,
    int _num_kv_heads)
    : IncMultiHeadSelfAttentionMeta(handler,
                                    BEAM_SEARCH_MODE,
                                    attn,
                                    attn->qSize,
                                    attn->kSize,
                                    attn->vSize,
                                    attn->qProjSize,
                                    attn->kProjSize,
                                    attn->vProjSize,
                                    attn->oProjSize,
                                    attn->apply_rotary_embedding,
                                    attn->qkv_bias,
                                    attn->scaling_query,
                                    attn->qk_prod_scaling,
                                    attn->position_bias,
                                    attn->final_bias,
                                    attn->scaling_factor,
                                    weight,
                                    gpu_mem_allocator,
                                    num_samples,
                                    attn->num_q_heads,
                                    attn->num_kv_heads,
                                    _num_q_heads,
                                    _num_kv_heads,
                                    DT_NONE,
                                    false) {
  cudaStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  checkCUDNN(cudnnSetStream(handler.dnn, stream));

  // allocate memory for the seqArray and reserve space
  {
    int max_tokens_per_batch = BatchConfig::max_tokens_per_batch();
    size_t beam_tokeninfo_size =
        max_tokens_per_batch * BeamSearchBatchConfig::MAX_BEAM_WIDTH;
    size_t requestinfo_size = BeamSearchBatchConfig::max_requests_per_batch();
    size_t beam_requestinfo_size =
        BeamSearchBatchConfig::max_requests_per_batch();
    size_t total_size =
        beam_tokeninfo_size *
            sizeof(BeamSearchBatchConfig::BeamSearchPerTokenInfo) +
        beam_requestinfo_size *
            sizeof(BeamSearchBatchConfig::
                       BeamSearchPerRequestInfo); // more components will
                                                  // be added here later

    // We always directly allocate memory for small speculative models
    gpu_mem_allocator.create_legion_instance(beam_search_reserve_inst,
                                             total_size);
    beam_token_infos =
        gpu_mem_allocator
            .allocate_instance<BeamSearchBatchConfig::BeamSearchPerTokenInfo>(
                beam_tokeninfo_size);
    // offset += beam_tokeninfo_size *
    //           sizeof(BeamSearchBatchConfig::BeamSearchPerTokenInfo);
    beam_request_infos =
        gpu_mem_allocator
            .allocate_instance<BeamSearchBatchConfig::BeamSearchPerRequestInfo>(
                beam_requestinfo_size);
    // offset += beam_requestinfo_size *
    //           sizeof(BeamSearchBatchConfig::BeamSearchPerRequestInfo);
    // assert(offset == total_size);
    assert(gpu_mem_allocator.instance_total_size ==
           gpu_mem_allocator.instance_allocated_size);
  }

  cudaStreamSynchronize(stream);
}

SpecIncMultiHeadSelfAttentionMeta::~SpecIncMultiHeadSelfAttentionMeta(void) {
  if (beam_search_reserve_inst != Realm::RegionInstance::NO_INST) {
    beam_search_reserve_inst.destroy();
  }
}

}; // namespace FlexFlow
