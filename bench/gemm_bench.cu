// gemm_bench.cu - before/after GEMM benchmark for the gpu-unlock speed selectors.
//
// Runs fixed-size cuBLAS GEMMs on one GPU (picked by PCI bus id) and reports
// TFLOPS, TFLOPS per GHz of measured SM clock, and a hash of each output so a
// later run can confirm bit-identical numerics.
//
// Build: nvcc -O2 -o gemm_bench gemm_bench.cu -lcublas -lnvidia-ml -lpthread
// Run:   ./gemm_bench [pci_bus_id] [json_out]
#include <cublas_v2.h>
#include <cuda_bf16.h>
#include <cuda_fp16.h>
#include <cuda_runtime.h>
#include <nvml.h>
#include <pthread.h>
#include <unistd.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <vector>

#define CK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { \
	fprintf(stderr, "%s:%d %s\n", __FILE__, __LINE__, cudaGetErrorString(e)); exit(1); } } while (0)
#define CB(x) do { cublasStatus_t s = (x); if (s != CUBLAS_STATUS_SUCCESS) { \
	fprintf(stderr, "%s:%d cublas %d\n", __FILE__, __LINE__, (int)s); exit(1); } } while (0)

static const int N = 8192, TRIALS = 7;

enum Scalar { S_F32, S_F16, S_I32 };

struct Case {
	const char *name, *note;
	cudaDataType ab, c;
	cublasComputeType_t compute;
	Scalar scalar;
	cublasOperation_t opa;
	int iters;
};

static const Case cases[] = {
	{"fp16-fp32acc", "throttled", CUDA_R_16F, CUDA_R_16F, CUBLAS_COMPUTE_32F, S_F32, CUBLAS_OP_N, 30},
	{"bf16-fp32acc", "throttled", CUDA_R_16BF, CUDA_R_16BF, CUBLAS_COMPUTE_32F, S_F32, CUBLAS_OP_N, 30},
	{"tf32", "throttled", CUDA_R_32F, CUDA_R_32F, CUBLAS_COMPUTE_32F_FAST_TF32, S_F32, CUBLAS_OP_N, 15},
	{"fp16-fp16acc", "control", CUDA_R_16F, CUDA_R_16F, CUBLAS_COMPUTE_16F, S_F16, CUBLAS_OP_N, 30},
	{"fp32-ffma", "in SS0 mask", CUDA_R_32F, CUDA_R_32F, CUBLAS_COMPUTE_32F_PEDANTIC, S_F32, CUBLAS_OP_N, 8},
	{"int8-int32acc", "in SS0 mask", CUDA_R_8I, CUDA_R_32I, CUBLAS_COMPUTE_32I, S_I32, CUBLAS_OP_T, 40},
};

static size_t esize(cudaDataType t)
{
	switch (t) {
	case CUDA_R_8I: return 1;
	case CUDA_R_16F: case CUDA_R_16BF: return 2;
	default: return 4;
	}
}

__device__ static uint32_t mix(uint32_t x)
{
	x ^= x >> 16; x *= 0x7feb352d; x ^= x >> 15; x *= 0x846ca68b; x ^= x >> 16;
	return x;
}

// Deterministic values in [-1, 1) (int8: [-64, 63]) so every run sees the same inputs.
__global__ void fill(void *p, size_t n, cudaDataType t, uint32_t seed)
{
	for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n; i += (size_t)gridDim.x * blockDim.x) {
		uint32_t h = mix((uint32_t)i * 2654435761u ^ seed);
		float v = (h >> 8) * (2.0f / 16777216.0f) - 1.0f;
		switch (t) {
		case CUDA_R_16F: ((__half *)p)[i] = __float2half(v); break;
		case CUDA_R_16BF: ((__nv_bfloat16 *)p)[i] = __float2bfloat16(v); break;
		case CUDA_R_8I: ((int8_t *)p)[i] = (int8_t)((int)(h >> 25) - 64); break;
		default: ((float *)p)[i] = v; break;
		}
	}
}

// NVML sampler: averages SM clock and power while `active` is set.
struct Sampler {
	nvmlDevice_t dev;
	volatile bool active = false, quit = false;
	double clk_sum = 0, pwr_sum = 0;
	long n = 0;
	unsigned long long reasons = 0;
};

static void *sample(void *arg)
{
	Sampler *s = (Sampler *)arg;
	while (!s->quit) {
		if (s->active) {
			unsigned int c, p;
			unsigned long long r;
			if (nvmlDeviceGetClockInfo(s->dev, NVML_CLOCK_SM, &c) == NVML_SUCCESS &&
			    nvmlDeviceGetPowerUsage(s->dev, &p) == NVML_SUCCESS) {
				s->clk_sum += c;
				s->pwr_sum += p / 1000.0;
				s->n++;
			}
			if (nvmlDeviceGetCurrentClocksEventReasons(s->dev, &r) == NVML_SUCCESS)
				s->reasons |= r;
		}
		usleep(10000);
	}
	return NULL;
}

static uint64_t fnv1a(const uint8_t *p, size_t n)
{
	uint64_t h = 0xcbf29ce484222325ull;
	for (size_t i = 0; i < n; i++)
		h = (h ^ p[i]) * 0x100000001b3ull;
	return h;
}

int main(int argc, char **argv)
{
	const char *bus = argc > 1 ? argv[1] : "0000:2D:00.0";
	const char *json = argc > 2 ? argv[2] : NULL;

	int devid;
	CK(cudaDeviceGetByPCIBusId(&devid, bus));
	CK(cudaSetDevice(devid));
	cudaDeviceProp prop;
	CK(cudaGetDeviceProperties(&prop, devid));

	if (nvmlInit() != NVML_SUCCESS) { fprintf(stderr, "nvmlInit failed\n"); return 1; }
	char nvbus[32];
	snprintf(nvbus, sizeof nvbus, "0000%s", bus);	// NVML wants the 8-digit domain
	Sampler smp;
	if (nvmlDeviceGetHandleByPciBusId(nvbus, &smp.dev) != NVML_SUCCESS) {
		fprintf(stderr, "NVML has no device %s\n", nvbus);
		return 1;
	}
	unsigned int plimit = 0;
	nvmlDeviceGetPowerManagementLimit(smp.dev, &plimit);
	pthread_t thr;
	pthread_create(&thr, NULL, sample, &smp);

	char host[64] = "";
	gethostname(host, sizeof host);
	FILE *cmd = fopen("/proc/cmdline", "r");
	char cmdline[1024] = "";
	if (cmd) { if (!fgets(cmdline, sizeof cmdline, cmd)) cmdline[0] = 0; fclose(cmd); }
	bool unlock_arg = strstr(cmdline, "gpu_unlock.targets=") != NULL;

	printf("%s  %s  %d SMs  power limit %u W  gpu_unlock arg on cmdline: %s\n",
	       bus, prop.name, prop.multiProcessorCount, plimit / 1000, unlock_arg ? "yes" : "no");
	printf("%dx%dx%d GEMM, %d trials, median reported\n\n", N, N, N, TRIALS);
	printf("%-14s %-12s %9s %9s %10s %7s %6s  %s\n",
	       "case", "note", "TFLOPS", "SM MHz", "TFLOPS/GHz", "watts", "spread", "output hash");

	cublasHandle_t h;
	CB(cublasCreate(&h));
	FILE *jf = json ? fopen(json, "w") : NULL;
	if (jf) {
		time_t now = time(NULL);
		char ts[32];
		strftime(ts, sizeof ts, "%Y-%m-%dT%H:%M:%S%z", localtime(&now));
		fprintf(jf, "{\"time\":\"%s\",\"host\":\"%s\",\"bus\":\"%s\",\"gpu\":\"%s\",\"unlock_arg\":%s,"
		        "\"n\":%d,\"results\":[", ts, host, bus, prop.name, unlock_arg ? "true" : "false", N);
	}

	size_t elems = (size_t)N * N;
	cudaEvent_t e0, e1;
	CK(cudaEventCreate(&e0));
	CK(cudaEventCreate(&e1));
	double flops = 2.0 * N * N * (double)N;

	for (size_t ci = 0; ci < sizeof cases / sizeof cases[0]; ci++) {
		const Case &k = cases[ci];
		void *A, *B, *C;
		CK(cudaMalloc(&A, elems * esize(k.ab)));
		CK(cudaMalloc(&B, elems * esize(k.ab)));
		CK(cudaMalloc(&C, elems * esize(k.c)));
		fill<<<1024, 256>>>(A, elems, k.ab, 1);
		fill<<<1024, 256>>>(B, elems, k.ab, 2);
		CK(cudaMemset(C, 0, elems * esize(k.c)));

		float af = 1, bf = 0;
		__half ah = __float2half(1.0f), bh = __float2half(0.0f);
		int32_t ai = 1, bi = 0;
		const void *alpha = k.scalar == S_F16 ? (const void *)&ah : k.scalar == S_I32 ? (const void *)&ai : &af;
		const void *beta = k.scalar == S_F16 ? (const void *)&bh : k.scalar == S_I32 ? (const void *)&bi : &bf;
		auto gemm = [&] {
			CB(cublasGemmEx(h, k.opa, CUBLAS_OP_N, N, N, N, alpha, A, k.ab, N, B, k.ab, N,
			                beta, C, k.c, N, k.compute, CUBLAS_GEMM_DEFAULT));
		};

		// Warm up for about two seconds so clocks and temperature settle.
		for (int i = 0; i < k.iters * 3; i++)
			gemm();
		CK(cudaDeviceSynchronize());

		// Hash one clean output before the timed loops.
		gemm();
		CK(cudaDeviceSynchronize());
		std::vector<uint8_t> out(elems * esize(k.c));
		CK(cudaMemcpy(out.data(), C, out.size(), cudaMemcpyDeviceToHost));
		uint64_t hash = fnv1a(out.data(), out.size());

		std::vector<double> tf;
		smp.clk_sum = smp.pwr_sum = 0;
		smp.n = 0;
		smp.reasons = 0;
		smp.active = true;
		for (int t = 0; t < TRIALS; t++) {
			CK(cudaEventRecord(e0));
			for (int i = 0; i < k.iters; i++)
				gemm();
			CK(cudaEventRecord(e1));
			CK(cudaEventSynchronize(e1));
			float ms;
			CK(cudaEventElapsedTime(&ms, e0, e1));
			tf.push_back(flops * k.iters / (ms * 1e-3) / 1e12);
		}
		smp.active = false;

		std::sort(tf.begin(), tf.end());
		double med = tf[TRIALS / 2], spread = (tf.back() - tf.front()) / med * 100;
		double mhz = smp.n ? smp.clk_sum / smp.n : 0, watts = smp.n ? smp.pwr_sum / smp.n : 0;
		double per_ghz = mhz ? med / (mhz / 1000) : 0;
		printf("%-14s %-12s %9.2f %9.0f %10.2f %7.0f %5.1f%%  %016llx\n",
		       k.name, k.note, med, mhz, per_ghz, watts, spread, (unsigned long long)hash);
		fflush(stdout);
		if (jf)
			fprintf(jf, "%s{\"case\":\"%s\",\"tflops\":%.3f,\"sm_mhz\":%.0f,\"tflops_per_ghz\":%.3f,"
			        "\"watts\":%.1f,\"spread_pct\":%.2f,\"clock_event_reasons\":\"0x%llx\",\"hash\":\"%016llx\"}",
			        ci ? "," : "", k.name, med, mhz, per_ghz, watts, spread, smp.reasons,
			        (unsigned long long)hash);

		CK(cudaFree(A));
		CK(cudaFree(B));
		CK(cudaFree(C));
	}
	if (jf) {
		fprintf(jf, "]}\n");
		fclose(jf);
	}

	smp.quit = true;
	pthread_join(thr, NULL);
	cublasDestroy(h);
	nvmlShutdown();
	return 0;
}
