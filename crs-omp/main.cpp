//  Created by Liu Chengjian on 17/10/9.
//  Copyright (c) 2017 csliu. All rights reserved.
//

#include <sys/time.h>
#include "GCRSMatrix.h"
#include "utils.h"

#include "kernels.cpp"

int main(int argc, const char * argv[]) {

  if (argc != 3) {
    printf("Usage: ./%s workSizePerDataParityBlockInMB numberOfTasks\n", argv[0]);
    exit(0);
  }

  int bufSize = atoi(argv[1]) * 1024 * 1024; // workSize per data parity block
  int taskNum = atoi(argv[2]);


#ifdef DUMP
  for (int m = 4; m <= 4; ++m) {
  for (int n = 8; n <= 8; ++n) {  // w is updated in the nested loop
  for (int k = MAX_K; k <= MAX_K; ++k) {
#else
  for (int m = 1; m <= 4; ++m) {
  for (int n = 4; n <= 8; ++n) {  // w is updated in the nested loop
  for (int k = m; k <= MAX_K; ++k) {
#endif

    int w = gcrs_check_k_m_w(k, m, n);
    if (w < 0) continue;

    printf("k:%d, m:%d w:%d\n",k,m,w);

    int *bitmatrix = gcrs_create_bitmatrix(k, m, w);
    //printMatrix(bitmatrix, k*w, m*w);

    //  adjust the bufSize
    int bufSizePerTask = align_value(bufSize / taskNum, sizeof(long) * w);
    bufSize = bufSizePerTask * taskNum;

    //  compute the bufSize for the last task
    int bufSizeForLastTask = bufSize - (bufSizePerTask * (taskNum - 1));
    printf("Total Size:%d Size per task:%d Size for last task:%d\n", 
        bufSize, bufSizePerTask, bufSizeForLastTask);

    // allocate host buffers
    char* data = (char*) malloc (bufSize * k);
    char* code = (char*) malloc (bufSize * m);

    // initialize host buffer
    generateRandomValue(data, bufSize * k);

    int dataSizePerAssign = bufSizePerTask * k;
    int codeSizePerAssign = bufSizePerTask * m;

    // taskSize will determine the number of kernels to run on a device
    int taskSize = 1;
    int mRemain = m;

    // adjust taskSize
    if (m >= MAX_M) {
      taskSize = m / MAX_M;
      if (m % MAX_M != 0) ++taskSize;
    }

    printf("task size: %d\n", taskSize);

    // set up kernel execution parameters
    int *mValue = (int*) malloc (sizeof(int) * taskSize);
    int *index = (int*) malloc (sizeof(int) * taskSize);
    coding_func *coding_function_ptrs = (coding_func*) malloc (sizeof(coding_func) * taskSize);

    for (int i = 0; i < taskSize; ++i) {
      if (mRemain < MAX_M) {
        mValue[i] = mRemain;
      }else{
        mValue[i] = MAX_M;
        mRemain = mRemain - MAX_M;
      }

      if (i == 0) {
        index[i] = 0;
      }else{
        index[i] = index[i-1] + k * w;
      }
      coding_function_ptrs[i] = coding_func_array[(mValue[i] - 1) * (MAX_W - MIN_W + 1)+ w - MIN_W];
    }

    //  create and then update encoding bit matrix
    unsigned int *all_columns_bitmatrix = (unsigned int*) malloc (sizeof(unsigned int) * k * w * taskSize);

    int mValueSum = 0;
    for (int i = 0; i < taskSize; ++i) {

      unsigned int *column_bitmatrix = gcrs_create_column_coding_bitmatrix(
          k, mValue[i], w, bitmatrix + k * w * mValueSum * w);

      memcpy((all_columns_bitmatrix + i * k * w), column_bitmatrix, k * w * sizeof(unsigned int));

      free(column_bitmatrix);
      mValueSum += mValue[i];
    }

// TODO
//#pragma omp target data map(alloc: data[0:bufSize*k], code[0:bufSize*m])
#pragma omp target data map(to: data[0:bufSize*k]) map(from: code[0:bufSize*m]) \
                        map(to: all_columns_bitmatrix[0:k*w*taskSize])
{
    int warpThreadNum = 32;
    int threadNum = MAX_THREAD_NUM;
    size_t workSizePerWarp = warpThreadNum / w * w;
    size_t workSizePerBlock = threadNum / warpThreadNum * workSizePerWarp * sizeof(size_t);
    size_t blockNum = bufSizePerTask / workSizePerBlock;

    if ((bufSizePerTask % workSizePerBlock) != 0) {
      blockNum = blockNum + 1;
    }

    printf("#blocks: %zu  blockSize: %d\n", blockNum, threadNum);

    struct timeval startEncodeTime, endEncodeTime;
    gettimeofday(&startEncodeTime, NULL);

    for (int i = 0; i < taskNum; ++i) {
      int count = (i == taskNum-1) ? bufSizeForLastTask : bufSizePerTask;

      // TODO
      //#pragma omp target update to (data[i*k*bufSizePerTask : i*k*bufSizePerTask + k*count])

      int workSizePerGrid = count / sizeof(long);
      int size = workSizePerGrid * sizeof(long);
      mValueSum = 0;
      for (int j = 0; j < taskSize; ++j) {
        coding_function_ptrs[j](k, index[j], 
          (long*)(data + dataSizePerAssign * i), 
          (long*)(code + codeSizePerAssign * i + mValueSum * size),
          all_columns_bitmatrix, 
          threadNum, blockNum, workSizePerGrid);

        mValueSum += mValue[j];
      }
      // TODO
      //#pragma omp target update from (code[i*m*bufSizePerTask : i*m*bufSizePerTask + m*count])
    }
    gettimeofday(&endEncodeTime, NULL);
    printf("Total elapsed time %lf (ms)\n",
      elapsed_time_in_ms(startEncodeTime, endEncodeTime));
}

#ifdef DUMP
    for (int i = 0; i < bufSize*m; i++) printf("%d\n", code[i]);
    printf("\n");
#endif

    free(mValue);
    free(index);
    free(coding_function_ptrs);
    free(bitmatrix);
    free(all_columns_bitmatrix);
    free(code);
    free(data);
  }
  }
  }

  return 0;
}
