---
name: ssh-perf
description: Walk through Brendan Gregg's 60-second Linux performance checklist on the active SSH or local shell session. Triggers on: slow, performance, bottleneck, high load, high CPU, high latency, latency spike, throughput, hung, unresponsive, perf issue.
---

# ssh-perf skill

Walk the user through Brendan Gregg's 60-second Linux performance checklist. You **observe only** — you cannot run commands yourself. For each step:

1. Explain what the command reveals (one sentence).
2. Present the exact command in a fenced code block for the user to paste in the **left pane**.
3. After the user runs it, read the result using `read_session_since` (use `focus_session` for the very first step to establish your cursor).
4. Interpret the key fields (1–2 lines) and note any findings.
5. Advance to the next step.

Maintain a running checklist at the top of each reply so progress survives context compaction:

```
[ ] 1. uptime
[ ] 2. dmesg | tail
...
```

Mark each step `[x] done — <one-line finding>` when complete. After all 10 steps, summarize the top-3 likely bottlenecks and suggest follow-up commands the user can run.

---

## The checklist

### Step 1 — uptime

Reveals: load averages over 1, 5, and 15 minutes. Rising load means a growing queue of runnable processes.

```
uptime
```

Look at: the 1-min vs 15-min averages. Load > number of CPUs = saturation. A 1-min load significantly higher than 15-min = recent spike; lower = load is fading.

---

### Step 2 — dmesg | tail

Reveals: recent kernel messages — OOM kills, hardware errors, driver resets, TCP drops.

```
dmesg | tail -20
```

Look at: "Out of memory: Kill process", "SCSI error", "dropped packet", "NMI", "BUG:", soft lockup warnings.

---

### Step 3 — vmstat 1

Reveals: CPU, memory, swap, and I/O at 1-second intervals (run for 5–10 seconds then Ctrl-C).

```
vmstat 1
```

Look at:
- `r` (run queue) > number of CPUs = CPU saturation
- `si`/`so` (swap in/out) > 0 = memory pressure / thrashing
- `us`+`sy` ≈ 100% with low `id` = CPU bound
- `wa` (I/O wait) high = disk bottleneck

---

### Step 4 — mpstat -P ALL 1

Reveals: per-CPU utilization. Identifies whether load is balanced or concentrated on one core.

```
mpstat -P ALL 1 3
```

Look at: any single CPU at 100% `%usr`+`%sys` while others are idle = single-threaded bottleneck or IRQ affinity issue. High `%iowait` = I/O bound.

---

### Step 5 — pidstat 1

Reveals: per-process CPU and context switch rates.

```
pidstat 1 3
```

Look at: processes with highest `%CPU`. High `cswch/s` (voluntary context switches) = sleeping frequently, possibly I/O-bound. High `nvcswch/s` (involuntary) = CPU-starved, being preempted.

---

### Step 6 — iostat -xz 1

Reveals: disk utilization, throughput, and latency per device.

```
iostat -xz 1 3
```

Look at:
- `%util` near 100% = device saturated
- `await` (ms) high = slow disk or saturated queue
- `r_await` vs `w_await` = distinguish read vs write latency
- `avgqu-sz` (average queue size) > 1 = backlog building

---

### Step 7 — free -m

Reveals: memory usage including buffers/cache and swap.

```
free -m
```

Look at: `available` column — if close to 0, memory is truly exhausted. `swap used` > 0 confirms paging. Cache is reclaimable; low `available` despite high cache = fragmentation or huge pages.

---

### Step 8 — sar -n DEV 1

Reveals: network throughput and error rates per interface.

```
sar -n DEV 1 3
```

Look at:
- `rxkB/s` + `txkB/s` — compare against known NIC speed (1 Gbps = ~125 MB/s)
- `rxerr/s` + `txerr/s` > 0 = hardware/driver errors
- `rxdrop/s` + `txdrop/s` > 0 = kernel drop queue overflow

---

### Step 9 — sar -n TCP,ETCP 1

Reveals: TCP connection rates and error counters.

```
sar -n TCP,ETCP 1 3
```

Look at:
- `active/s` (outbound SYN) and `passive/s` (inbound SYN) — baseline connection rates
- `retrans/s` > 0 = packet loss or congestion
- `isegerr/s` > 0 = bad segments received

---

### Step 10 — top

Reveals: live process list, top CPU and memory consumers, overall system state.

```
top
```

Look at:
- Header: load, tasks, CPU split (user/system/iowait/steal)
- Top processes by `%CPU` and `%MEM`
- `S` column: `D` = uninterruptible sleep (waiting on I/O or kernel lock) — if many `D` state procs, disk or lock contention
- `steal` (`st`) > 0 = hypervisor taking CPU from this VM

---

## After step 10 — summary

Compile findings from the checklist. Identify the top-3 likely bottlenecks based on what was observed.

Suggest follow-up commands only as further actions for the user to run:

| Symptom | Follow-up command |
|---------|------------------|
| High CPU on specific function | `sudo perf top` |
| High disk latency / I/O wait | `sudo biolatency` (BCC), `sudo blktrace -d /dev/sdX` |
| TCP retransmits / connection issues | `ss -tiepm` |
| OOM / memory fragmentation | `cat /proc/buddyinfo`, `sudo slabtop` |
| Soft lockup / hung tasks | `sudo dmesg -T | grep -i lockup` |
