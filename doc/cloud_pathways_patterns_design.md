# Design: Cloud Pathways Patterns for the OpenStudio Server Run Controller

**Status:** Draft design note — for review, no implementation yet
**Date:** 9 Nov 2026
**Companion document:** The deployment-side half of this design lives in
[NatLabRockies/openstudio-server-helm](https://github.com/NatLabRockies/openstudio-server-helm)
at `docs/cloud-pathways-patterns-design.md`. This document covers the
run-controller logic in this repository; that document covers the Helm
chart templates that deploy it.
**Source:** Google Cloud Blog, "Cloud Pathways, a distributed ML runtime,
is GA" (9 Nov 2026)

## Recommendation

Do **not** adopt Cloud Pathways. It is a JAX runtime for Google Cloud TPUs
(v5e / v5p / Trillium v6e / Ironwood 7x) on GKE, requiring JAX 0.10.1+.
OpenStudio / EnergyPlus workloads are CPU-based, embarrassingly parallel
simulations — no accelerator, no JAX, no inter-simulation communication.

**Do adopt three of its patterns**, using native Kubernetes primitives.
Pathways is Google's production answer, at Gemini scale, to problems
OpenStudio Server also has: a long analysis should not die because one
worker died, one controller should see the whole analysis, and heavy data
work should happen on the worker node, not through the server. This
repository owns pattern 1, and defines the contracts patterns 2 and 3
depend on.

## The patterns, as application work

### 1. Single-controller orchestration

Pathways replaces multi-controller execution — every host running its own
interpreter in lockstep — with one client that orchestrates the whole run.
For OpenStudio Server: one run controller owns an analysis end-to-end —
datapoint manifest, Job creation, status, retries, and result collection —
and is the sole writer of run state. Workers stay stateless and disposable;
no worker decides run-level policy. Store the manifest (inputs, seed,
measure versions, weather-file hash) durably so a restarted controller
resumes from it rather than from in-memory state. The chart work to deploy
this controller is in the companion document in openstudio-server-helm.

### 2. Elastic fault tolerance — the completion contract

Pathways decouples job survival from a single slice, resharding to N-1
slices on a hardware failure without crashing the client. The server-side
equivalent is a completion contract: a datapoint is done only when its
outputs are committed to object storage with a completion marker. On
restart or reschedule, the controller reconciles markers, and re-queues
only missing or incomplete datapoints — completed datapoints are never
re-run, and a lost worker costs at most its in-flight datapoints.

### 3. Colocated sidecars — the staging contract

Pathways runs sidecars on accelerator hosts for data loading and
checkpointing locally instead of via the controller. The server-side
contract the sidecar implements (chart templates are in the companion
document): fetch the OSW, measures, and weather file for a datapoint and
verify hashes before the simulation starts; on completion, upload results
and logs and write the completion marker, even if the simulation process
crashed. Defining that contract here keeps pre/post-processing (e.g.
surrogate-model inputs) out of the simulation image.

Lower priority: Pathways' shared, long-running pool tapped interactively
from notebooks maps to a shared server pool for exploratory analyses.
Defer until patterns 1–3 land — interactive sharing multiplies scheduling
and fairness problems.

## What not to copy

TPU/GKE lock-in; a single controller as an unprotected single point of
failure (a self-hosted controller needs restart-from-manifest, above);
and hyperscale assumptions. Pathways overhead pays off at thousands of
accelerators and is a net cost at small scale.

## Proposed test

Run one representative analysis on the refactored Jobs path and report:
(1) kill a worker node mid-run — does the analysis complete, re-running
only in-flight datapoints? (2) restart the controller mid-run — does it
resume from the manifest/markers with no duplicate completed work?
(3) wall-clock and cost vs. the current path at the same datapoint count.
Passing all three is the gate for making this the default execution path.

---

*Prepared from the GA announcement only. No Pathways evaluation, GCP
account, or TPU access is proposed. Revisit adoption only if a future
surrogate-model effort is written in JAX, trained at large scale, and
funded for GCP TPUs.*
