#include <stdio.h>
#include <stdlib.h>
#include <chrono>
#include <vector>
#include <hip/hip_runtime.h>

// Example
// https://pytorch.org/docs/stable/generated/torch.flip.html

template <typename scalar_t>
__global__ void flip_kernel(
    const scalar_t* in_tensor,
          scalar_t* out_tensor,
    int64_t  n,
    const int64_t* flip_dims,
    const int64_t  flip_dims_size,
    const int64_t* strides,
    const int64_t* strides_contiguous,
    const int64_t* shape,
    const int64_t  total_dims) 
{
  int64_t linear_index = blockIdx.x * blockDim.x + threadIdx.x;

  if (linear_index >= n) return;

  int64_t cur_indices = linear_index;
  int64_t rem = 0;
  int64_t dst_offset = 0;

  for (int64_t i = 0; i < total_dims; i++) {
    int64_t temp = cur_indices;
    cur_indices = cur_indices / strides_contiguous[i];
    rem = temp - cur_indices * strides_contiguous[i];
    for (int64_t j = 0; j < flip_dims_size; j++) {
      // flip the indices if it is in flip_dims
      if (i == flip_dims[j]) {
        cur_indices = shape[i] - 1 - cur_indices;
      }
    }
    dst_offset += cur_indices * strides[i];
    cur_indices = rem;
  }
  out_tensor[linear_index] = in_tensor[dst_offset];
}

// display the values of a property in a tensor
void property (const char* name, std::vector<int64_t> p)
{
  printf("%s: ( ", name);
  for (uint64_t i = 0; i < p.size(); i++) {
    printf("%lu ", p[i]);
  }
  printf(")\n");
}

template <typename scalar_t>
void flip (const int64_t num_dims, const int64_t num_flip_dims,
           const int32_t dim_size, const int32_t repeat)
{
  std::vector<int64_t> flip;
  std::vector<int64_t> shape;
  std::vector<int64_t> stride;

  for (int64_t i = 0; i < num_dims; i++) {
#ifdef EXAMPLE
    shape.push_back(2);
#else
    shape.push_back(dim_size);
#endif
  }

  int64_t n = 1;
  for (int64_t i = 0; i < num_dims; i++) {
    n = n * shape[i];
  }

  for (int64_t i = 0; i < num_flip_dims; i++) {
    flip.push_back(i);
  }

  stride.push_back(shape[1] * shape[2]);
  stride.push_back(shape[2]);
  stride.push_back(1);

  property("shape", shape);
  property("flip_dims", flip);
  property("stride", stride);

  int64_t dims_bytes = num_dims * sizeof(int64_t);
  int64_t flip_dims_bytes = num_flip_dims * sizeof(int64_t);
  int64_t input_size_bytes = n * sizeof(scalar_t);
  int64_t output_size_bytes = input_size_bytes;

  scalar_t *input = (scalar_t*) malloc (input_size_bytes);

  for (int i = 0; i < n; i++) {
    input[i] = (scalar_t) i;
  }

  scalar_t *output = (scalar_t*) malloc(output_size_bytes);

  scalar_t *d_input, *d_output;
  hipMalloc((void**)&d_input, input_size_bytes);
  hipMemcpy(d_input, input, input_size_bytes, hipMemcpyHostToDevice);

  hipMalloc((void**)&d_output, output_size_bytes);

  int64_t *d_flip_dims, *d_shape, *d_strides, *d_strides_contiguous;

  hipMalloc((void**)&d_flip_dims, flip_dims_bytes);
  hipMemcpy(d_flip_dims, flip.data(), flip_dims_bytes, hipMemcpyHostToDevice);

  hipMalloc((void**)&d_shape, dims_bytes);
  hipMemcpy(d_shape, shape.data(), dims_bytes, hipMemcpyHostToDevice);

  hipMalloc((void**)&d_strides, dims_bytes);
  hipMemcpy(d_strides, stride.data(), dims_bytes, hipMemcpyHostToDevice);

  hipMalloc((void**)&d_strides_contiguous, dims_bytes);
  hipMemcpy(d_strides_contiguous, stride.data(), dims_bytes, hipMemcpyHostToDevice);

  const int threadsPerBlock = 256;
  dim3 grid ((n + threadsPerBlock - 1) / threadsPerBlock);
  dim3 block (threadsPerBlock);

  hipDeviceSynchronize();
  auto start = std::chrono::steady_clock::now();

  for (int i = 0; i < repeat; i++) {
    flip_kernel<scalar_t><<<grid, block>>> (
      d_input,
      d_output,
      n,
      d_flip_dims,
      num_flip_dims,
      d_strides,
      d_strides_contiguous,
      d_shape,
      num_dims);
  }

  hipDeviceSynchronize();
  auto end = std::chrono::steady_clock::now();
  auto time = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
  printf("Average execution time of the flip kernel: %f (ms)\n", (time * 1e-6f) / repeat);

  hipMemcpy(output, d_output, output_size_bytes, hipMemcpyDeviceToHost);

#ifdef EXAMPLE
  for (int i = 0; i < n; i++) {
    printf("%f ", output[i]);
  }
  printf("\n");
#endif

  free(input);
  free(output);
  hipFree(d_input);
  hipFree(d_output);
  hipFree(d_flip_dims);
  hipFree(d_shape);
  hipFree(d_strides);
  hipFree(d_strides_contiguous);
}

int main(int argc, char* argv[])
{
  if (argc != 4) {
    printf("Usage: %s <number of dimensions> <size of each dimension> <repeat>\n", argv[0]);
    return 1;
  }

  const int64_t num_dims = atoi(argv[1]);
  const int64_t dim_size = atoi(argv[2]);
  const int32_t repeat = atoi(argv[3]);

#ifdef EXAMPLE
  const int64_t num_flip_dims = 2;
#else
  const int64_t num_flip_dims = num_dims;
#endif

  printf("=========== Data type is FP32 ==========\n");
  flip<float>(num_dims, num_flip_dims, dim_size, repeat);

  printf("=========== Data type is FP64 ==========\n");
  flip<double>(num_dims, num_flip_dims, dim_size, repeat);

  return 0;
}
