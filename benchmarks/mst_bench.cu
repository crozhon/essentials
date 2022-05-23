#include <gunrock/error.hxx>
#include <gunrock/graph/graph.hxx>
#include <gunrock/formats/formats.hxx>
#include <gunrock/cuda/cuda.hxx>
#include <gunrock/framework/operators/for/for.hxx>
#include <nvbench/nvbench.cuh>
#include <iostream>
#include <gunrock/algorithms/algorithms.hxx>
#include <gunrock/algorithms/mst.hxx>
#include <gunrock/algorithms/bfs.hxx>
#include <cxxopts.hpp>

using namespace gunrock;
using namespace memory;

std::string filename;  // Global

void mst_bench(nvbench::state& state) {
  // Add metrics.
  state.collect_dram_throughput();
  state.collect_l1_hit_rates();
  state.collect_l2_hit_rates();
  state.collect_loads_efficiency();
  state.collect_stores_efficiency();

  // --
  // Define types
  using csr_t =
      format::csr_t<memory_space_t::device, vertex_t, edge_t, weight_t>;

  // --
  // Build graph + metadata
  csr_t csr;
  if (util::is_market(filename)) {
    io::matrix_market_t<vertex_t, edge_t, weight_t> mm;
    csr.from_coo(mm.load(filename));
  } else if (util::is_binary_csr(filename)) {
    csr.read_binary(filename);
  } else {
    std::cerr << "Unknown file format: " << filename << std::endl;
    exit(1);
  }

  thrust::device_vector<vertex_t> row_indices(csr.number_of_nonzeros);
  thrust::device_vector<vertex_t> column_indices(csr.number_of_nonzeros);
  thrust::device_vector<edge_t> column_offsets(csr.number_of_columns + 1);

  auto G =
      graph::build::from_csr<memory_space_t::device,
                             graph::view_t::csr /* | graph::view_t::csc */>(
          csr.number_of_rows,               // rows
          csr.number_of_columns,            // columns
          csr.number_of_nonzeros,           // nonzeros
          csr.row_offsets.data().get(),     // row_offsets
          csr.column_indices.data().get(),  // column_indices
          csr.nonzero_values.data().get(),  // values
          row_indices.data().get(),         // row_indices
          column_offsets.data().get()       // column_offsets
      );

  // Initialize the context.
  cuda::device_id_t device = 0;
  cuda::multi_context_t context(device);

  // --
  // Params and memory allocation
  thrust::device_vector<weight_t> mst_weight(1);

  // --
  // Run MST with NVBench
  state.exec(nvbench::exec_tag::sync, [&](nvbench::launch& launch) {
    gunrock::mst::run(G, mst_weight.data().get());
  });
}

int main(int argc, char** argv) {
  filename = argv[1];

  // Create a new argument array without filename to pass to NVBench.
  char* args[argc - 1];
  args[0] = argv[0];
  for (int i = 1; i < argc; i++) {
    args[i] = argv[i + 1];
  }

  NVBENCH_BENCH(mst_bench);
  NVBENCH_MAIN_BODY(argc - 1, args);
}