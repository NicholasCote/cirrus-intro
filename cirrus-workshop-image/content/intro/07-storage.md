# 7. Storage

← [Secret Manager](06-secrets.md) · next: [GitHub Actions](08-github-actions.md)

A container's filesystem is disposable, and pods are replaced routinely. So
anything you want to still exist tomorrow has to live somewhere that is not the
pod. There are four such places on CIRRUS, they behave completely differently,
and choosing the wrong one is the most common early architecture mistake here.

---

## The four options, side by side

| | what it is | shared between pods? | good for | not for |
| --- | --- | --- | --- | --- |
| **PVC, `ceph-kubepv`** | a block device, Ceph RBD | **no** — one node at a time | a database, a cache, one writer | anything with several replicas writing |
| **PVC, `cephfs`** | a POSIX filesystem, CephFS | **yes** — many readers and writers | shared uploads, generated output, a scratch area | very high-rate small writes |
| **S3** | object storage, replicated between both sites | yes, over HTTP | datasets, artifacts, anything a URL can serve | anything expecting a filesystem |
| **NFS / GLADE** | an existing NCAR export, mounted in | yes, read-only | reading data that already exists on GLADE | writing, or anything CIRRUS-native |

The one-line heuristic: **if it looks like a filesystem, use a PVC; if it looks
like a bucket of files, use S3; if the data already exists on GLADE, mount it
read-only and do not copy it.**

---

## PersistentVolumeClaims and storage classes

[Page 3](03-kubernetes.md#persistentvolumeclaims) introduced the object. This is
what the numbers and the class names actually mean on CIRRUS.

Storage is **Ceph-backed**, and there are two classes:

```yaml
# ReadWriteOnce -- Ceph RBD, a block device
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-rdb
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-kubepv
  resources:
    requests:
      storage: 10Gi
```

```yaml
# ReadWriteMany -- CephFS, a shared filesystem
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-fs
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: cephfs
  resources:
    requests:
      storage: 10Gi
```

Then mount it in the pod, which is the same for both:

```yaml
spec:
  containers:
    - name: my-app
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: my-app-fs
```

### Access modes are the decision that matters

This is worth labouring, because the failure is subtle rather than loud.

**`ReadWriteOnce` means one *node* at a time.** Not one pod — one node. So a
Deployment with `replicas: 3` and one RWO claim will do one of two things
depending on where the scheduler puts the pods: work by accident, because all
three landed on the same node, or leave pods stuck in `ContainerCreating`
forever, because the volume is already attached elsewhere. Both are bad, and the
first is worse, because it works in test and fails after an upgrade moves a pod.

**If more than one replica needs to write, you need `ReadWriteMany`** —
`cephfs`. If you take one thing from this page, take that.

And a related trap: RWO plus a rolling update. The new pod cannot attach the
volume until the old pod releases it, and the old pod does not terminate until
the new one is ready. That deadlock is why single-writer workloads usually want
`strategy: type: Recreate` rather than the default `RollingUpdate`.

### Sizing, growing, and quota

```bash
kubectl get pvc
kubectl describe pvc <name>
kubectl describe resourcequota      # storage counts against this
```

* **Storage counts against your namespace quota**, and it keeps counting while a
  volume is bound and idle. A claim you have forgotten is quota you cannot use.
* **Volumes can grow, in place.** Change the `storage:` request in your chart —
  `5Gi` to `50Gi` — commit, and let Argo CD sync; the volume is expanded. This is
  the documented fix for a full PVC and it needs no downtime.
* **Volumes cannot shrink.** Ever. So start smaller than you think you need and
  grow, rather than the reverse.
* **Ask before you ask for something large.** The cluster is shared and the quota
  conversation is short if you bring a number.

### What a PVC does not give you

* **It is not a backup.** The SLA is explicit that applications are recovered by
  redeploying from git, not by restoring machines. A PVC holding something
  irreplaceable needs a deliberate plan — **replication across the two sites is
  available on request**, and requesting it is on you.
* **It is not portable between clusters.** A volume on `mlc1` is on `mlc1`.
* **It does not survive namespace deletion.** Which is one more reason a real
  application belongs in a project namespace rather than a personal one.

---

## GLADE, and why your session can see it but your Deployment cannot

Your `$HOME` is mounted into *this* session — it is NFS, shared with Casper and
Derecho, and it is there because this OnDemand session's pod spec asked for it.

```bash
df -h ~ | tail -1
```

**Do not assume a Deployment you write can see it.** It cannot, unless the mount
was configured for it, and that is a request rather than a field you set. When it
is granted, it looks like an ordinary NFS volume:

```yaml
volumes:
  - name: glade-campaign
    nfs:
      server: <nfs server FQDN>
      path: /campaign
      readOnly: true
```

Two things to expect:

* **It is read-only.** GLADE access from CIRRUS is granted read-only, which is
  the right default: a service that can write to a shared filesystem used by two
  supercomputers is a large blast radius.
* **It is the right answer for "compute next to the data".** If a dashboard reads
  a 4 TB dataset that already exists on GLADE, mounting it beats copying it into
  a PVC by every measure.

The `nfs-vol-helm` chart in
[cirrus-examples](https://github.com/NCAR/cirrus-examples) is the working shape.

---

## S3 object storage

CIRRUS runs an **S3-compatible object store on site**, and it is the option
people under-use. It is not a filesystem — no POSIX semantics, no directories
that really exist, no partial writes — and in exchange it is highly available and
**replicated between ML and NWSC**, so a bucket keeps serving when a site goes
down. Nothing else in this list does that.

**Endpoint:** `https://s3.k8s.ucar.edu:5443`

Use it for datasets, model output, generated tiles, artifacts, anything a URL can
serve, and anything two applications need to share without a shared filesystem.
There is no GUI for browsing buckets; access is programmatic.

### Getting credentials

An account is created automatically the first time you connect with UCAR
credentials. The bootstrap is a little unusual — you build a token from your
username and password:

```json
{
  "RGW_TOKEN": {
    "version": 1,
    "type": "ldap",
    "id": "your_username",
    "key": "your_clear_text_password_here"
  }
}
```

```bash notebook-skip
cat token.json | base64        # this is your AWS_ACCESS_KEY_ID
```

```bash notebook-skip
export AWS_ACCESS_KEY_ID=<the base64 string>
export AWS_SECRET_ACCESS_KEY="asdf"   # must be non-empty; some tools object otherwise
```

**Use that once, to create the account, and then stop.** It embeds your UCAR
password in cleartext, and the documentation is explicit that it is not
recommended beyond the first connection.

Your real, CIRRUS-specific keys are issued separately. Launch the **CIRRUS S3
Keys** app in Open OnDemand and it prints your `aws_access_key_id` and
`aws_secret_access_key`. That page refreshes hourly, so allow a little time
between the automatic account creation and the keys appearing.

Put them in `~/.aws/credentials` and the endpoint in `~/.aws/config`:

```ini
# ~/.aws/config
[default]
endpoint_url = https://s3.k8s.ucar.edu:5443
```

```ini
# ~/.aws/credentials
[default]
aws_access_key_id=...
aws_secret_access_key=...
```

For an application, the keys belong in **OpenBao** and reach the pod as an
ExternalSecret — [page 6](06-secrets.md). Not in the image, not in the chart.

### Using it

```bash notebook-skip
# s5cmd -- the recommended client, and substantially faster than the others
s5cmd --endpoint-url https://s3.k8s.ucar.edu:5443 mb s3://my-bucket
s5cmd --endpoint-url https://s3.k8s.ucar.edu:5443 cp ./data.nc s3://my-bucket/
s5cmd --endpoint-url https://s3.k8s.ucar.edu:5443 ls s3://my-bucket/

# aws cli -- official, more widely documented
aws --endpoint-url https://s3.k8s.ucar.edu:5443 s3 ls
aws --endpoint-url https://s3.k8s.ucar.edu:5443 s3 cp ./data.nc s3://my-bucket/
```

From Python, `boto3`:

```python
import boto3

s3 = boto3.client("s3", endpoint_url="https://s3.k8s.ucar.edu:5443")
s3.upload_file("data.nc", "my-bucket", "data.nc")
```

The `--endpoint-url` flag (or `endpoint_url`) is the whole difference from
talking to AWS, and forgetting it is the standard first error — the call goes to
Amazon, and fails on credentials that mean nothing there.

Worth knowing if you work with scientific data: `s3fs`, `fsspec`, `xarray`,
`zarr` and `intake` all take an `endpoint_url` in their storage options, so a
Zarr store on this system can be opened directly by an analysis or a dashboard.
That is the pattern behind several of the applications on
<https://cirrus.k8s.ucar.edu/apps>: write the store once from a batch job, serve
it lazily from a container.

---

## Where the workshop session's own files go

Worth being explicit, since it is a live example of every rule above:

| path | what it is | survives? |
| --- | --- | --- |
| `~/cirrus-workshop/` | your GLADE home, mounted in by the OOD pod spec | **yes** |
| `/tmp/cirrus/` | the pod's own disk — caches, tokens, editor state | no |
| `/opt/cirrus/` | the image | it *is* the image |

```bash
df -h ~ /tmp/cirrus | tail -2
```

Your work goes in `~/cirrus-workshop/`. Everything else is scratch, and the pod
takes it when it goes.

---

## Check yourself

1. You have a Deployment with three replicas that all write to the same
   directory. Which storage class, and what happens if you choose the other one?
2. Your PVC is full. What do you change, and does it need downtime?
3. Which of the four options survives one of the two sites going down?
4. Your dashboard needs to read a dataset that already exists on GLADE. What is
   the wrong approach, and what is the right one?
5. Where do S3 credentials live for a deployed application, and where do they
   definitely not live?
6. Name two things a PVC does not give you that people assume it does.

---

← [6. Secret Manager](06-secrets.md) · next: [8. GitHub Actions](08-github-actions.md)
