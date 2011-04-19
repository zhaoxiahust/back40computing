/******************************************************************************
 * 
 * Copyright 2010 Duane Merrill
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
 * 
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 * Thanks!
 * 
 ******************************************************************************/

/******************************************************************************
 * Kernel runtime statistics
 ******************************************************************************/

#pragma once

#include <b40c/util/error_utils.cuh>
#include <b40c/util/cuda_properties.cuh>

namespace b40c {
namespace util {


/**
 * Manages device storage needed for conveying kernel runtime stats
 */
class KernelRuntimeStats
{
protected :


	// Counters in global device memory
	clock_t* d_stat;

	// Start time
	clock_t start;
	clock_t accumulated;

public:

	/**
	 * Constructor
	 */
	KernelRuntimeStats() :
		d_stat(NULL),
		accumulated(0) {}

	/**
	 * Marks start time.  Typically called by thread-0.
	 */
	__device__ __forceinline__ void MarkStart()
	{
		start = clock();
	}

	/**
	 * Marks stop time.  Typically called by thread-0.
	 */
	__device__ __forceinline__ void MarkStop(bool complete = true)
	{
		clock_t stop = clock();
		clock_t runtime = (stop >= start) ?
			stop - start :
			stop + (((clock_t) -1) - start);
		accumulated += runtime;

		if (complete) {
			d_stat[blockIdx.x] = accumulated;
		}
	}

	/**
	 * Resets statistic. Typically called by thread-0.
	 */
	__device__ __forceinline__ void Reset() const
	{
		d_stat[blockIdx.x] = 0;
	}

};


/**
 * Version of global barrier with storage lifetime management.
 *
 * We can use this in host enactors, and pass the base GlobalBarrier
 * as parameters to kernels.
 */
class KernelRuntimeStatsLifetime : public KernelRuntimeStats
{
protected:

	// Number of bytes backed by d_stat
	size_t stat_bytes;

public:

	/**
	 * Constructor
	 */
	KernelRuntimeStatsLifetime() : KernelRuntimeStats(), stat_bytes(0) {}


	/**
	 * Deallocates and resets the progress counters
	 */
	cudaError_t HostReset()
	{
		cudaError_t retval = cudaSuccess;
		if (d_stat) {
			retval = util::B40CPerror(cudaFree(d_stat), "KernelRuntimeStatsLifetime cudaFree d_stat failed: ", __FILE__, __LINE__);
			d_stat = NULL;
		}
		stat_bytes = 0;
		return retval;
	}


	/**
	 * Destructor
	 */
	virtual ~KernelRuntimeStatsLifetime()
	{
		HostReset();
	}


	/**
	 * Sets up the progress counters for the next kernel launch (lazily
	 * allocating and initializing them if necessary)
	 */
	cudaError_t Setup(int sweep_grid_size)
	{
		cudaError_t retval = cudaSuccess;
		do {
			size_t new_stat_bytes = sweep_grid_size * sizeof(clock_t);
			if (new_stat_bytes > stat_bytes) {

				if (d_stat) {
					if (retval = util::B40CPerror(cudaFree(d_stat),
						"KernelRuntimeStatsLifetime cudaFree d_stat failed", __FILE__, __LINE__)) break;
				}

				stat_bytes = new_stat_bytes;

				if (retval = util::B40CPerror(cudaMalloc((void**) &d_stat, stat_bytes),
					"KernelRuntimeStatsLifetime cudaMalloc d_stat failed", __FILE__, __LINE__)) break;

				// Initialize to zero
				util::MemsetKernel<clock_t><<<(sweep_grid_size + 128 - 1) / 128, 128>>>(
					d_stat, 0, sweep_grid_size);
				if (retval = util::B40CPerror(cudaThreadSynchronize(),
					"KernelRuntimeStatsLifetime MemsetKernel d_stat failed", __FILE__, __LINE__)) break;
			}
		} while (0);

		return retval;
	}


	/**
	 * Returns ratio of (avg cta runtime : total runtime)
	 */
	double AvgLive(int sweep_grid_size)
	{
		clock_t *h_stat = (clock_t*) malloc(stat_bytes);

		util::B40CPerror(cudaMemcpy(h_stat, d_stat, stat_bytes, cudaMemcpyDeviceToHost),
			"KernelRuntimeStatsLifetime d_stat failed", __FILE__, __LINE__);

		// Compute runtimes, find max
		int ctas_with_work = 0;
		clock_t max_runtime = 0;
		unsigned long long total_runtimes = 0;
		for (int block = 0; block < sweep_grid_size; block++) {

			clock_t runtime = h_stat[block];

			if (runtime > max_runtime) {
				max_runtime = runtime;
			}

			total_runtimes += runtime;
			ctas_with_work++;
		}

		// Compute avg runtime
		double avg_runtime = (ctas_with_work > 0) ?
			double(total_runtimes) / ctas_with_work :
			0.0;

		free(h_stat);

		return (max_runtime > 0) ?
			avg_runtime / max_runtime :
			0.0;
	}


	/**
	 * Returns ratio of (avg cta runtime : total runtime)
	 */
	cudaError_t Accumulate(int sweep_grid_size, long long &total_avg_live, long long &total_max_live)
	{
		clock_t *h_stat = (clock_t*) malloc(stat_bytes);

		cudaError_t retval = util::B40CPerror(cudaMemcpy(h_stat, d_stat, stat_bytes, cudaMemcpyDeviceToHost),
			"KernelRuntimeStatsLifetime d_stat failed", __FILE__, __LINE__);

		// Compute runtimes, find max
		int ctas_with_work = 0;
		clock_t max_runtime = 0;
		unsigned long long total_runtimes = 0;
		for (int block = 0; block < sweep_grid_size; block++) {

			clock_t runtime = h_stat[block];

			if (runtime > max_runtime) {
				max_runtime = runtime;
			}

			total_runtimes += runtime;
			ctas_with_work++;
		}

		// Compute avg runtime
		double avg_runtime = (ctas_with_work > 0) ?
			double(total_runtimes) / ctas_with_work :
			0.0;

		free(h_stat);

		total_max_live += max_runtime;
		total_avg_live += avg_runtime;

		return retval;
	}
};




} // namespace util
} // namespace b40c

