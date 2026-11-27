# Frontier AI OS: honest scope

Status: scope contract.  This document exists to stop overclaiming.

## Verdict

TBs of RAM is **necessary** for 70B-405B Q4/Q8 weights plus long-context KV,
and for checkpointable agents.  It is **not sufficient** for frontier AI.

A CPU-only, no-GPU, no-fabric OS will not be adopted to train frontier models.
The credible target is a **single-node, memory-centric, verifiable inference
and agent appliance**, not a replacement for a hyperscale training stack.

## Where this OS can win

- A model vendor ships a sealed appliance: encrypted weights, capability-bound
  tools, deterministic traces, checkpoint/restore, no host POSIX layer.
- Single-node inference of 7B-405B Q4/Q8 with 1-4 TB RAM and long KV.
- Sovereign / regulated deployments where verifiability and isolation matter
  more than raw token throughput.
- Research on deterministic, checkpointable agents and replayable traces.
- Memory-centric serving: zero-copy weights, NUMA placement, huge pages,
  per-agent KV slabs, live model generations.

## What is still missing for frontier adoption

- **Accelerators**: PCIe/IOMMU, GPU/TPU drivers, VRAM allocation, DMA,
  GPUDirect/RDMA, vendor firmware.  Without this, CPU only is niche.
- **Fabric**: NVLink/InfiniBand/RoCE, collectives, multi-node KV and
  checkpoint transport.
- **Model runtime**: GGUF/ONNX/safetensors import, tokenizer, Q4/Q8/fp8
  kernels, attention/MoE, sampling, batching, an OpenAI/gRPC API.
- **Frameworks**: PyTorch/JAX/ONNX Runtime integration or a credible
  replacement; CUDA/ROCm compatibility is a separate project.
- **Storage**: NVMe, GPUDirect Storage, streaming multi-TB weights, tiering.
- **Reliability/security**: ECC/RAS, hotplug, attestation, multi-tenant
  isolation, audit, OOM/eviction, power loss.
- **Ecosystem/ops**: Kubernetes/device plugins, observability, quotas,
  support, certification.

## Required stack

```
native multicore substrate
  memory: 4-level paging, 1GB pages, E820/SRAT, NUMA, hugepage allocator,
          memory objects/caps, OOM/tiering, ECC/RAS
  compute: AVX-512/AMX, GPU/accelerator boundary, DMA/IOMMU
  I/O: NVMe, PCIe, RDMA, model streaming
NaN layer:
  ISA/block translator, scheduler, capabilities, checkpoints, tensors/KV,
  traces/generations, model runtime, agent tools
interfaces:
  model import, token API, tool API, trace/replay API, ops API
```

## Memory contract

- Pointers/sizes/offsets are 64-bit `(lo,hi)`; TBs and 4 GiB crossings are
  normal.
- 5-level paging, 52-bit physical (4 PiB), 57-bit virtual (128 PiB),
  1 GiB direct-map pages, per-NUMA-node free lists, 16 KiB per-core stacks
  for 4096-core scale.
- Weight objects are read-only capabilities; KV/activation objects are
  per-agent, 64-byte aligned, zero-copy views; checkpoint roots are sealed.
- The native substrate maps and protects; the NaN layer owns placement,
  eviction, generation and checkpoint policy.

## Gates that would make a claim credible

- `mem64_gate`: native 5-level tables, full 4 PiB direct map, 1 TiB
  mapping, 2 MiB/4 KiB leaves, MAXPHYADDR/canonical rejection. PASS.
- `nmem_scale_gate`: 2 TiB memory object + 1 TiB view, 64-bit caps. PASS.
- `nansmp`: 2/4 CPU now; 64/128 CPU on a suitable host.
- `nan_q4lm`: exact Q4 GEMV/token loop; then measured tokens/s on real
  hardware.
- Model import + KV long-context gate; checkpoint/restore on another node.
- Accelerator DMA/IOMMU gate before any GPU performance claim.

## Non-claims

- No frontier-training claim.
- No GPU/TPU support claim until drivers/DMA/IOMMU gates pass.
- No multi-node/fabric claim until RDMA/collective gates pass.
- No "faster than CUDA" claim; CPU-only is not competitive for frontier
  throughput.
- TBs RAM alone does not make an AI OS attractive; the model runtime,
  accelerators, fabric and ecosystem do.
