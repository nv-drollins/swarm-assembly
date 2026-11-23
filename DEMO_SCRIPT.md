# 🐝 Swarm Assembly — Booth Demo Script (3.5–4.5 Minutes)

**Setup on screen before starting:**
- Browser open to `http://<spark-1-host>:4456` in full-screen (`F11`).
- All 8 specialists sitting idle on the bottom **Bench** (4 on **Spark 1** in green, 4 on **Spark 2** in purple), **Supervisor** at top-center, and both live GPU/memory telemetry bars ticking at ~1 Hz.

---

## Part 1: The Hook & The 2-Spark Cluster (0:00 – 0:45)

**[GESTURE TO THE TWO PHYSICAL DGX SPARKS, THEN THE SPLIT CANVAS]**

> "What you're looking at is a live multi-agent AI software team running completely locally across **two NVIDIA DGX Sparks** sitting right here on the table. Nothing is hitting the cloud, and nothing is pre-recorded or simulated.
>
> Each DGX Spark gives us a Grace Blackwell GB10 superchip with **121 gigabytes of unified memory** — and the two units are linked directly together over their **dual 200-gigabit ConnectX-7 RDMA ports**.
>
> That high-speed link lets us do two things at the same time:
> 1. **First, model sharding across the cluster:** Look at the **Supervisor** at the top of the screen. That's **NVIDIA Nemotron-3-Super — a 120-billion-parameter reasoning model** in NVFP4. Using tensor parallelism (`TP=2`) over the 200-gigabit ConnectX-7 fabric, that 120B model is stretched across **both Sparks simultaneously** (~40 GB per node), acting as the brain of the cluster.
> 2. **Second, distributed specialist models:** With ~80 GB of unified memory still free on each box, we host a fleet of **24-to-30-billion-parameter specialist models** across the two nodes — `Devstral-Small-2-24B` for coding on Spark 1, and `Nemotron-3-Nano-30B` and `Gemma-4-26B` for research, analysis, architecture, and writing on Spark 2."

---

## Part 2: Why Sub-Agents & a Supervisor? (0:45 – 1:30)

**[POINT TO THE SUPERVISOR AT TOP-CENTER AND THE 8 IDLE BENCH AGENTS AT THE BOTTOM]**

> "Why build a system this way instead of throwing one giant prompt at a single model?
>
> Three reasons:
> 1. **Right model for the job:** A model tuned to write tight Python code (`Devstral-24B`) isn't the same model you want critiquing system architecture or writing executive prose (`Gemma-4-26B`), or doing fast analytical reasoning (`Nemotron-3-Nano-30B`).
> 2. **Clean, focused context:** When one monolithic model tries to plan, code, test, review, and document in a single pass, its context window fills with its own noise. Separate sub-agents get a clean role prompt and see only the distilled output of the teammates before them.
> 3. **Dynamic resource efficiency:** Look at the **Bench** at the bottom — we have 8 specialists (`Researcher`, `Coder`, `Designer`, `Analyst`, `Architect`, `Writer`, `Reviewer`, `Tester`). We don't wake up all 8 for a 3-step job.
>
> The **120B Nemotron Supervisor** reads the user's request, reasons about what skills are actually required, **recruits only the sub-agents needed**, spins up an isolated **NVIDIA NemoClaw / OpenShell sandbox** where they can safely execute real code, and disbands the team when the job is done."

---

## Part 3: Demo 1 — Small, Dynamically Recruited Team (`▶ Build a Small Tool`) (1:30 – 2:45)

**[CLICK `▶ Build a Small Tool` IN THE BOTTOM-RIGHT CONTROLS]**

> "Let's run a focused task first: *'Design, build, and test a small Python utility that summarizes a directory.'* I haven't told the system which agents to use — watch the Supervisor figure that out."

**[WHAT TO POINT OUT AS IT RUNS:]**

1. **`RECRUIT` phase (Top-Center & Activity Feed):**
   > "Watch both GPU bars spike together — that's the **120B Nemotron Supervisor** thinking across both Sparks over the 200GbE link. In the log on the right, you can see its live `💭` reasoning trace: it decides it only needs **three** specialists — **Architect**, **Coder**, and **Tester** — and leaves the other five on the bench."
2. **`ASSEMBLE` phase (Middle Work Zones):**
   > "Those three agents animate off the bench into the active **NemoClaw sandbox** zones on Spark 1 and Spark 2."
3. **`RELAY` phase (Watch the GPU Bars Alternate):**
   > "Now watch the compute load move between the two machines:
   > - First, **Spark 2** lights up in purple as the **Architect** designs the utility.
   > - Next, the baton passes to **Spark 1** in green — the **Coder** (`Devstral-24B`) writes the Python script and **actually executes it (`⚙️ rc=0`)** inside the shared NemoClaw sandbox.
   > - Then the **Tester** writes and runs a verification test against it in that same sandbox."
4. **`SYNTHESIZE & DISBAND` phase:**
   > "The Supervisor synthesizes the final summary, clears the sandbox, and sends the three agents back to the bench. Notice at the bottom of the report we can **Download** the Python code they wrote or click **▶ Re-test in sandbox** to run it live again."

---

## Part 4: Demo 2 — Full-Swarm Multi-Round Build (`▶ Build a Data Pipeline`) (2:45 – 4:15)

**[CLICK `▶ Build a Data Pipeline` IN THE BOTTOM-RIGHT CONTROLS]**

> "Now let's look at the opposite extreme — a full software lifecycle task: *'Build a Python data pipeline that reads a text dataset, computes word-frequency statistics, validates the output, reviews the code, fixes any issues, analyzes the metrics, designs the report layout, and documents it.'*
>
> Watch the bench at the bottom — **all 8 specialists** get recruited across both DGX Sparks."

**[WHAT TO POINT OUT AS IT RUNS:]**

1. **The Whole Bench Empties:**
   > "All 8 specialists move into the shared workspace across Spark 1 and Spark 2."
2. **Click-to-Inspect Feature (Interactive UI Moment):**
   > *(Click on the **Coder** or **Reviewer** circle on the canvas while it works)*
   > "By the way, if you ever want to zero in on a single specialist while the swarm is running, you can click any agent node on the canvas to filter the live stream to just that agent's thinking and code execution — and click again to see the whole team."
3. **Multi-Round Iterative Loop (`Coder — round 1` → `Tester` → `Reviewer` → `Coder — round 2`):**
   > "Here's what makes a real agentic workflow different from a one-shot prompt:
   > - After the **Researcher** and **Architect** set the spec, the **Coder** writes **Round 1** of the pipeline and runs it in the sandbox.
   > - The **Tester** runs automated checks on it, and the **Reviewer** (`Nemotron-3-Nano-30B` on Spark 2) critiques the code for edge cases and risks.
   > - Then look — the **Coder is called back for Round 2 (`— round 2 —`)**, reads the Reviewer's feedback, patches the script, and re-executes it in the sandbox (`rc=0`).
   > - Finally, the **Analyst**, **Designer**, and **Writer** take the verified output from the sandbox and turn it into the finished report."
4. **Live Re-Test Payoff:**
   > *(When the Final Result appears, click **`▶ Re-test in sandbox`**)*
   > "And just to prove that code is real — if I click **Re-test in sandbox**, it re-runs the swarm's Python pipeline inside NemoClaw right now and prints the live output (`✓ rc=0`)."

---

## Part 5: Wrap-Up / Takeaway (4:15 – 4:30)

> "So in two deskside boxes connected by a single 200-gigabit cable, we're running a **120-billion-parameter Nemotron Supervisor** sharded across both nodes, **three 24-to-30-billion-parameter specialist models**, and a live code-execution sandbox — giving you a complete, private, self-assembling AI engineering team on your desk."

---

## Quick Presenter Cheat-Sheet (Booth Q&A)

| Question | 1-Liner Answer |
|---|---|
| **"What models are running right now?"** | **Supervisor:** `NVIDIA Nemotron-3-Super-120B-A12B-NVFP4` (sharded `TP=2` across both Sparks) · **Coder/Tester:** `Mistral Devstral-Small-2-24B-FP8` · **Researcher/Analyst/Reviewer/Designer:** `NVIDIA Nemotron-3-Nano-30B-A3B-NVFP4` · **Architect/Writer:** `Google/NVIDIA Gemma-4-26B-A4B-NVFP4`. |
| **"Why do the log lines have different colors?"** | **Teal** = 120B Supervisor · **Green** = specialist running on Spark 1 · **Purple** = specialist running on Spark 2. |
| **"Where does the Python code actually run?"** | Inside an isolated, non-root **NVIDIA NemoClaw / OpenShell** container sandbox (`swarm-team`) on Spark 1 — never on the host OS. |
| **"How fast is the link between the two Sparks?"** | Dual-rail **200 GbE RoCEv2** over ConnectX-7 (`MTU 9000`), configured for direct GPU-to-GPU RDMA tensor parallelism. |
