#include <cassert>
#include <iostream>
#include <cuda.h>
#include <cuda_runtime.h>
#include <mma.h>
#include <cuda_fp16.h>

#include "../util.h"

#define N 128
#define M 768
#define K 3072

#define KBLOCK 8

using namespace nvcuda;

__global__ void vanilla(half *a, half *b, float *c) {
  int x = blockIdx.y;
  int y = blockIdx.x;

  wmma::fragment<wmma::matrix_a, 16, 16, 16, half, wmma::row_major> a_frag;
  wmma::fragment<wmma::matrix_b, 16, 16, 16, half, wmma::row_major> b_frag;
  wmma::fragment<wmma::accumulator, 16, 16, 16, float, void> c_frag;
  wmma::fill_fragment(c_frag, 0.0f);

  for (int k = 0; k < K; k += 16) {
    wmma::load_matrix_sync(a_frag, a + (x * 16) * K + k, K);
    wmma::load_matrix_sync(b_frag, b + k * M + y * 16, M);
    wmma::mma_sync(c_frag, a_frag, b_frag, c_frag);
  }

  wmma::store_matrix_sync(c + (x * 16) * M + (y * 16), c_frag, M, wmma::mem_row_major);
}


__global__ void splitk(half *a, half *b, float *c) {
  int x = blockIdx.y;
  int y = blockIdx.x;
  __shared__ float spad[16 * 16 * KBLOCK];

  wmma::fragment<wmma::matrix_a, 16, 16, 16, half, wmma::row_major> a_frag;
  wmma::fragment<wmma::matrix_b, 16, 16, 16, half, wmma::row_major> b_frag;
  wmma::fragment<wmma::accumulator, 16, 16, 16, float, void> c_frag;
  wmma::fill_fragment(c_frag, 0.0f);

  for (int k_inner = 0; k_inner < (K / KBLOCK); k_inner += 16) {
    int k = threadIdx.y * (K / KBLOCK) + k_inner;
    wmma::load_matrix_sync(a_frag, a + (x * 16) * K + k, K);
    wmma::load_matrix_sync(b_frag, b + k * M + y * 16, M);
    wmma::mma_sync(c_frag, a_frag, b_frag, c_frag);
  }

  wmma::store_matrix_sync(spad + 16 * 16 * threadIdx.y, c_frag, 16, wmma::mem_row_major);

  __syncthreads();

  int workidx = 32 * threadIdx.y + threadIdx.x;
  int workload = 256 / (32 * 2);

  for (int i = 0; i < workload; ++i) {
    #pragma UNROLL
    for (int j = 1; j < KBLOCK; ++j) {
      spad[workidx * workload + i] += spad[j * 16 * 16 + workidx * workload + i];
    }
    int xx = (threadIdx.x * 8 + i) % 16;
    int yy = (threadIdx.x * 8 + i) / 16;
    c[((x * 16) + xx) * M + (y * 16) + yy] = spad[workidx * workload + i];
  }

  // wmma::store_matrix_sync(c + (x * 16) * M + (y * 16), c_frag, M, wmma::mem_row_major);
}

half a[N * K], b[M * K];
float c[N * M], ref[N * M];

template<typename T>
void print(int n, int m, const T* a) {
  for (int i = 0; i < n; ++i) {
    for (int j = 0; j < m; ++j) {
      if (j) std::cout << " ";
      std::cout << a[i * m + j];
    }
    std::cout << std::endl;
  }
  std::cout << std::endl;
}

template<>
void print(int n, int m, const half* a) {
  for (int i = 0; i < n; ++i) {
    for (int j = 0; j < m; ++j) {
      if (j) std::cout << " ";
      std::cout << __half2float(a[i * m + j]);
    }
    std::cout << std::endl;
  }
  std::cout << std::endl;
}

void compare(int n, float *c, float *ref) {
  for (int i = 0; i < n; ++i) {
    if (fabs(c[i] - ref[i]) / ref[i] > 1e-3) {
      std::cout << i  << "\n" << c[i] << ", expect: " << ref[i] << " " << fabs(c[i] - ref[i]) / ref[i] << std::endl;
      throw;
    }
  }

}

int main() {
  cudaDeviceProp prop;
  assert(cudaSuccess == cudaGetDeviceProperties(&prop, 0));
  std::cout << "Warp size is: " <<  prop.warpSize << std::endl;

  for (int i = 0; i < N * K; ++i)
    a[i] = __float2half((float)(rand() % 100) / 100.);
  for (int i = 0; i < K * M; ++i)
    b[i] = __float2half((float)(rand() % 100) / 100.);
  for (int i = 0; i < N * M; ++i)
    c[i] = 0;
  for (int i = 0; i < N; ++i)
    for (int j = 0; j < M; ++j) {
      ref[i * M + j] = 0.0;
      for (int ko = 0; ko < KBLOCK; ++ko) {
        float sub = 0.0;
        for (int ki = 0; ki < K / KBLOCK; ki += 16) {
          float sum = 0;
          for (int kii = 0; kii < 16; ++kii) {
            int k = ko * (K / KBLOCK) + ki + kii;
            sum += __half2float(a[i * K + k]) * __half2float(b[k * M + j]);
          }
          sub += sum;
        }
        ref[i * M + j] += sub;
      }
    }
  half *dev_a, *dev_b;
  float *dev_c;
  cudaMalloc(&dev_a, N * K * sizeof(half));
  cudaMalloc(&dev_b, M * K * sizeof(half));
  cudaMalloc(&dev_c, N * M * sizeof(float));
  cudaMemcpy(dev_a, a, sizeof a, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_b, b, sizeof b, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_c, c, sizeof c, cudaMemcpyHostToDevice);

  std::cout.precision(5);
  {
    dim3 threads(32, 1, 1);
    dim3 blocks(M / 16, N / 16, 1);
    vanilla<<<blocks, threads>>>(dev_a, dev_b, dev_c);
    cudaDeviceSynchronize();
    begin_roi();
    vanilla<<<blocks, threads>>>(dev_a, dev_b, dev_c);
    cudaDeviceSynchronize();
    float elps = end_roi();
    std::cout << "time elps: " << elps << std::endl;
    cudaMemcpy(c, dev_c, sizeof c, cudaMemcpyDeviceToHost);
    compare(N * M, c, ref);
  }

  {
    dim3 threads(32, KBLOCK, 1);
    dim3 blocks(M / 16, N / 16);
    splitk<<<blocks, threads>>>(dev_a, dev_b, dev_c);
    cudaDeviceSynchronize();
    begin_roi();
    splitk<<<blocks, threads>>>(dev_a, dev_b, dev_c);
    cudaDeviceSynchronize();
    float elps = end_roi();
    std::cout << "time elps: " << elps << std::endl;
    cudaMemcpy(c, dev_c, sizeof c, cudaMemcpyDeviceToHost);
    compare(N * M, c, ref);
  }


  //print(N, M, a);
  //print(N, M, b);
  //print(N, K, c);
  //print(N, M, ref);
  return 0;
}
