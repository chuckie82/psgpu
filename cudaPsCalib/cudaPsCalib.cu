#include <stdio.h>
#include <cuda_profiler_api.h>

// TITAN X Spec
#define BLOCK_D1 1024
#define BLOCK_D2 1
#define BLOCK_D3 1

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

__global__ void kernel(short *a, int offset, short *dark, int offsetDark, int *sectorSum)
{
  // note that this assumes no third dimension to the grid
  // id of the block
  int myblock = blockIdx.x + blockIdx.y * gridDim.x;
  // size of each block (within grid of blocks)
  int blocksize = blockDim.x * blockDim.y * blockDim.z;
  // id of thread in a given block
  int subthread = threadIdx.z*(blockDim.x * blockDim.y) + threadIdx.y*blockDim.x + threadIdx.x;
  // assign overall id/index of the thread
  int idx = myblock * blocksize + subthread;

  a[idx + offset] -= 1;  
  // calculate sum per sector
  //int mySector = threadIdx.z + (offset / (blockDim.x * blockDim.y)); 
  //atomicAdd(&sectorSum[mySector], mySector);
  //sectorSum[mySector] = mySector;
}

__global__ void common_mode(int *blockSum, int *sectorMean, int offsetSector)
{
  int i = threadIdx.x + blockIdx.x * blockDim.x;

  // calculate sector mean
  atomicAdd(&sectorMean[offsetSector], blockSum[i]);
}

__global__ void common_mode_apply(short *a, int offset, int *sectorMean, int offsetSector, int sectorSize)
{
  int i = offset + threadIdx.x + blockIdx.x*blockDim.x;
  a[i] = a[i] - (sectorMean[offsetSector]/sectorSize);
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
    float error = fabs(a[i]-1.0f);
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

  const int nStreams = atoi(argv[2]);
  const int streamSize = ceil(n / nStreams);
  const int nSectors = maxQuads * maxSectors * nEvents;

  const int streamBytes = streamSize * sizeof(short);
  const int bytes = n * sizeof(short);
  const int darkBytes = nPixels * sizeof(short);
  const int sumSectorBytes = nSectors * sizeof(int);

  // a block has 1024 threads
  const dim3 blockSize(BLOCK_D1, BLOCK_D2, BLOCK_D3);
  printf("Block dimension is %i x %i x %i\n", BLOCK_D1, BLOCK_D2, BLOCK_D3);  

  // determine number of blocks we need for a given problem size
  int tmp = ceil(pow(n/(BLOCK_D1 * BLOCK_D2 * BLOCK_D3 * nStreams), 0.5));
  printf("Grid dimension is %i x %i\n", tmp, tmp);
  dim3 gridSize(tmp, tmp, 1);

  int nthreads = BLOCK_D1*BLOCK_D2*BLOCK_D3*tmp*tmp;
  if (nthreads < n){
    printf("\n================ NOT ENOUGH THREADS TO COVER N=%d =======================\n\n", n);
  } else {
    printf("Launching %d threads (N=%d)\n", nthreads, n);

  }
 
  printf("Running with nStreams: %d streamSize: %d\n", nStreams, streamSize);

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
  int *d_sectorSum, *sectorSum; // sum of each sector
  checkCuda( cudaMalloc((void**)&d_sectorSum, sumSectorBytes) ); 
  cudaMemset(d_sectorSum, 0, sumSectorBytes);
  sectorSum = (int *) malloc(sumSectorBytes);
  
  // prepare raw and dark data
  fill(a, n, 3);
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
    int offsetDark = offset % nPixels;
    printf("Stream :%d offset:%d offsetDark:%d\n", i, offset, offsetDark);
    checkCuda( cudaMemcpyAsync(&d_a[offset], &a[offset],
                               streamBytes, cudaMemcpyHostToDevice,
                               stream[i]) );
    kernel<<<gridSize, blockSize, 0, stream[i]>>>(d_a, offset, d_dark, offsetDark, d_sectorSum);
    checkCuda( cudaMemcpyAsync(&a[offset], &d_a[offset],
                               streamBytes, cudaMemcpyDeviceToHost,
                               stream[i]) );
  }
  
  //cudaMemcpy(sectorSum, d_sectorSum, sumSectorBytes, cudaMemcpyDeviceToHost);
  //for (int i =0; i< 10; i++){
  //  printf("i: %d, sectorSum[i]: %d \n", i, sectorSum[i]);
  //}
  printf("Output values: %d %d %d...%d %d %d\n", a[0], a[1], a[2], a[n-3], a[n-2], a[n-1]);
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