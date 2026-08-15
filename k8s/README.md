# Kubernetes deployment

Runs the mirror on a cluster with dynamic volume provisioning. The database is
a `StatefulSet` on a `PersistentVolumeClaim`, the webapp a `Deployment` behind
a `LoadBalancer` service.

## Deploy

```sh
mise run k8s-up       # namespace, secret, manifests
mise run k8s-status   # pods, import progress, address
```

The manifests pull the images published by `.github/workflows/images.yml`, so
nothing needs building first. To run your own, point `REGISTRY` at your
namespace, `mise run k8s-images`, and edit the `image:` lines. They must be
**linux/amd64** and pullable by the cluster: either keep the registry packages
public, or add an `imagePullSecret` to the pod specs.

The import takes 20-40 minutes, during which the database pod stays
`0/1 Running`. Its readiness probe runs `pg_isready -h 127.0.0.1`, and the
`-h` matters: the entrypoint keeps PostgreSQL on its unix socket for the whole
import, so a probe without it would reach that temporary server and report
ready while the data is still loading. The webapp waits in an init container
rather than crash-looping meanwhile.

**An interrupted import leaves a silently incomplete database.** The volume
persists, so on restart the entrypoint finds a valid `PGDATA` and skips the
init scripts — including the import — for good. `mise run k8s-status` prints
the project count, which should be around 2.1 million; anything well below
that means starting over from an empty claim.

The public address appears as soon as the load balancer is provisioned, well
before the data is ready:

```sh
kubectl -n repology get svc repology-webapp
```

## Storage: volumes, not image layers

The cluster needs a StorageClass — check with `kubectl get sc`. The volume is
claimed through the StatefulSet's `volumeClaimTemplates`, so it keeps its
identity across restarts and is **not** deleted with the pod: restarting the
database does not trigger a re-import.

50 GiB for 25 GiB of data plus WAL. If the dataset outgrows it, a storage
class with `ALLOWVOLUMEEXPANSION` lets you raise the claim in place.

**A CSI driver does not make node disk a non-issue.** It provisions volumes
*mounted into* pods; container images are unpacked by containerd onto the
node's own filesystem, and nothing in the Kubernetes API can redirect that
elsewhere. The two are separate, which is why shipping the dataset inside an
image is a dead end here — `kubectl get --raw /api/v1/nodes/<node>/proxy/stats/summary`
reports `imagefs` and `nodefs` with the same capacity, the node's disk.

A node offering 39 GiB has around 19 GiB free once the OS and other images are
accounted for, against 25 GiB unpacked for a dump-carrying image plus the
compressed layer held during extraction. The pod is evicted with `The node was
low on resource: ephemeral-storage`, and the resulting `DiskPressure` taint
then blocks rescheduling until kubelet reclaims space. An `emptyDir` fails the
same way, for the same reason. Sizing the claim is not optional here.

## Restricting the database

`30-networkpolicy.yaml` limits ingress to pods labelled `app=repology-webapp`
on 5432, on top of the password held in the `repology-db` Secret. Egress stays
open: the database downloads the dump itself.

The policy is enforced here by Cilium. A cluster whose CNI ignores
`NetworkPolicy` accepts the object and silently does nothing with it, so check
before relying on it:

```sh
kubectl -n kube-system get ds | grep -E 'cilium|calico|antrea|kube-router'
```

It governs the pod network only. `kubectl exec` and `kubectl port-forward`
reach pods through the kubelet and bypass it entirely, so namespace RBAC
remains the other half.

## Building the images

The database image cross-builds fine from any host — gcc and cmake emulate
without trouble.

**The webapp image does not cross-build from arm64.** `rustc` segfaults under
QEMU, failing at `rustc -vV` before compiling a single crate:

```
error: process didn't exit successfully: `.../bin/rustc -vV`
       (signal: 11, SIGSEGV: invalid memory reference)
qemu: uncaught target signal 11 (Segmentation fault) - core dumped
```

Three ways around it, in rough order of preference:

1. **Build on an amd64 machine** — a CI runner, or any x86_64 host. This is
   what `Dockerfile.webapp` expects and it needs no special setup.
2. **Enable Rosetta in Docker Desktop** on Apple Silicon. It requires
   `UseVirtualizationFramework` and `UseVirtualizationFrameworkRosetta`, which
   changes the VM backend and needs a restart of Docker Desktop.
3. **Reuse a binary compiled natively elsewhere.** An image that only copies
   in an existing `repology-webapp` and `libversion.so*` never runs the
   toolchain under emulation.

## Staying current

Neither half updates itself without `40-refresh.yaml`. The database imports
once against an empty volume and the entrypoint then skips its init scripts
for good; the webapp pod keeps whatever image it started with, however often
the registry moves. Both go stale silently, which is the worst way to fail.

Two CronJobs fix that. Upstream publishes a new dump daily around 04:00 UTC.

**`repology-refresh`, 05:00 UTC.** Replaying a `pg_dump --clean` into the live
database would leave it inconsistent for the whole restore, so the job builds a
sibling database instead, checks it holds at least 1.5 M projects with both
extensions, and only then swaps by rename. A failed check drops the sibling and
leaves the live database untouched.

The rename needs zero connections, so the job terminates the webapp's sessions
first; its pool reconnects by name and lands on the new data by itself. That
reconnection is the entire downtime — no rollout, and therefore no RBAC.

This is why the claim is 80 GiB rather than 50: for the length of the import
the volume holds both copies.

**`repology-webapp-update`, 06:30 UTC**, after the image workflow has had time
to publish. `kubectl rollout restart` recreates the pod, which pulls the
current image because the Deployment sets `imagePullPolicy: Always` — that
setting alone changes nothing, since it only applies when a pod is created. A
ServiceAccount grants `get` and `patch` on that one Deployment by name, and
nothing else. With a single replica the rollout surges before terminating, so
the site stays up.

Either can be run early:

```sh
kubectl -n repology create job --from=cronjob/repology-refresh refresh-now
```

The refresh pod is an ordinary client of the database, so it is named in the
NetworkPolicy alongside the webapp. Dropping that label is the kind of change
that surfaces at 05:00 as a connection timeout looking nothing like a firewall
rule.
