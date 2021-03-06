#include <stdio.h>
#include <cuda_profiler_api.h>

#define N_PIXELS 2296960
#define SECTOR_SIZE 71780

// Convenience function for checking CUDA runtime API results
// can be wrapped around any runtime API call. No-op in release builds.
inline
cudaError_t checkCuda(cudaError_t result)
{
#if defined(DEBUG) || defined(_DEBUG)
  if (result != cudaSuccess) {
    fprintf(stderr, "CUDA Runtime Error: %s\n", cudaGetErrorString(result));
    assert(result == cudaSuccess);
  }
#endif
  return result;
}

__global__ void kernel(short *a, int offset, short *dark, int *blockSum)
{
  int i = offset + threadIdx.x + blockIdx.x*blockDim.x;
  int iDark = i % N_PIXELS;
  a[i] -= dark[iDark];
  
  // calculate sum per block
  int iBlock = floor( (double) i / blockDim.x );
  atomicAdd(&blockSum[iBlock], a[i]);
}

__global__ void common_mode(int *blockSum, int offset, int *sectorSum)
{
  int i = offset + threadIdx.x + blockIdx.x * blockDim.x;

  // calculate sector sum
  int iSector = floor( (double) i / blockDim.x );
  atomicAdd(&sectorSum[iSector], blockSum[i]);
}

__global__ void common_mode_apply(short *a, int offset, int *sectorSum)
{
  int i = offset + threadIdx.x + blockIdx.x*blockDim.x;
  int iSector = floor( (double) i / SECTOR_SIZE );
  a[i] = a[i] - (sectorSum[iSector] / SECTOR_SIZE);
}

/* ---------------------- host code -----------------------------*/
void fill( short *p, int n, int val ) {
  for(int i = 0; i < n; i++){
    p[i] = val;
  }
}

float maxError(short *a, int n)
{
  float maxE = 0;
  for (int i = 0; i < n; i++) {
    float error = fabs(a[i]-0.0f);
    if (error > maxE) maxE = error;
  }
  return maxE;
}

int main(int argc, char **argv)
{
  const int maxQuads = 4, maxSectors = 8;
  const int nColumns = 185, nRows = 388;
  const int nPixels = nColumns * nRows * maxSectors * maxQuads;
  const int nEvents = atoi(argv[1]);
  const int n = nPixels * nEvents;

  int nStreams = 32;
  if (argc > 2) nStreams = atoi(argv[2]);
  const int streamSize = n / nStreams;
  const int streamBytes = streamSize * sizeof(short);
  
  const int bytes = n * sizeof(short);
  
  const int darkBytes = nPixels * sizeof(short);
  
  const int blockSize = 185;
  const int nBlocks = n / blockSize;
  const int blockSumBytes = nBlocks * sizeof(int);
  
  const int nSectors = nBlocks / nRows;   
  const int sectorSumBytes = nSectors * sizeof(int);

  printf("Running with nStreams: %d streamSize: %d\n", nStreams, streamSize);
  int gridSize = streamSize / blockSize;
  printf("blockSize: %d gridSize: %d\n", blockSize, gridSize);
  
  int devId = 0;
  if (argc > 3) devId = atoi(argv[3]);
  
  cudaDeviceProp prop;
  checkCuda( cudaGetDeviceProperties(&prop, devId));
  printf("Device : %s\n", prop.name);
  checkCuda( cudaSetDevice(devId) );

  // allocate pinned host memory and device memory
  short *a, *d_a; // data
  checkCuda( cudaMallocHost((void**)&a, bytes) ); // host pinned
  checkCuda( cudaMalloc((void**)&d_a, bytes) ); // device  
  
  short *dark, *d_dark; // dark
  checkCuda( cudaMallocHost((void**)&dark, darkBytes) ); 
  checkCuda( cudaMalloc((void**)&d_dark, darkBytes) ); 
  
  int *d_blockSum; // sum of each block
  checkCuda( cudaMalloc((void**)&d_blockSum, blockSumBytes) ); 
  cudaMemset(d_blockSum, 0, blockSumBytes);
  
  int *d_sectorSum; // sum of each sector
  checkCuda( cudaMalloc((void**)&d_sectorSum, sectorSumBytes) );
  cudaMemset(d_sectorSum, 0, sectorSumBytes);
  
  // prepare raw and dark data
  fill(a, n, 2);
  fill(dark, nPixels, 1);
  printf("Input values (Data): %d %d %d...%d %d %d\n", a[0], a[1], a[2], a[n-3], a[n-2], a[n-1]);
  printf("Input values (Dark): %d %d %d...%d %d %d\n", dark[0], dark[1], dark[2], dark[nPixels-3], dark[nPixels-2], dark[nPixels-1]);

  // serial copy for one dark 
  checkCuda( cudaMemcpy(d_dark, dark, darkBytes, cudaMemcpyHostToDevice) );

  float ms; // elapsed time in milliseconds

  // create events and streams
  cudaEvent_t startEvent, stopEvent, dummyEvent;
  cudaStream_t stream[nStreams];
  checkCuda( cudaEventCreate(&startEvent) );
  checkCuda( cudaEventCreate(&stopEvent) );
  checkCuda( cudaEventCreate(&dummyEvent) );
  for (int i = 0; i < nStreams; ++i)
    checkCuda( cudaStreamCreate(&stream[i]) );

  // asynchronous version 1: loop over {copy, kernel, copy}
  checkCuda( cudaEventRecord(startEvent, 0) );
  cudaProfilerStart();
  for (int i = 0; i < nStreams; ++i) {
    int offset = i * streamSize;
    int offsetSector = i * (streamSize / blockSize);
    checkCuda( cudaMemcpyAsync(&d_a[offset], &a[offset],
                               streamBytes, cudaMemcpyHostToDevice,
                               stream[i]) );
    kernel<<<gridSize, blockSize, 0, stream[i]>>>(d_a, offset, d_dark, d_blockSum);
    common_mode<<<nBlocks/(nStreams * nRows), nRows, 0, stream[i]>>>(d_blockSum, offsetSector, d_sectorSum); 
    common_mode_apply<<<gridSize, blockSize, 0, stream[i]>>>(d_a, offset, d_sectorSum);
    checkCuda( cudaMemcpyAsync(&a[offset], &d_a[offset],
                               streamBytes, cudaMemcpyDeviceToHost,
                               stream[i]) );
  }
  cudaProfilerStop(); 
  checkCuda( cudaEventRecord(stopEvent, 0) );
  checkCuda( cudaEventSynchronize(stopEvent) );
  checkCuda( cudaEventElapsedTime(&ms, startEvent, stopEvent) );
  printf("Time for asynchronous V1 transfer and execute (ms): %f\n", ms);
  printf("  max error: %e\n", maxError(a, n));
  
  // cleanup
  checkCuda( cudaEventDestroy(startEvent) );
  checkCuda( cudaEventDestroy(stopEvent) );
  checkCuda( cudaEventDestroy(dummyEvent) );
  for (int i = 0; i < nStreams; ++i)
    checkCuda( cudaStreamDestroy(stream[i]) );
  cudaFree(d_a);
  cudaFreeHost(a);
  //cudaFree(d_dark);
  //cudaFreeHost(dark);

  return 0;
}
