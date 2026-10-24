# AutoDay: Scheduling Algorithm & System Reference (v1)

> **AutoDay is not a task manager. It is a decision engine that plans the student's day so they don't have to.**

---

## 1. Product Context (locked)

**Problem.** Students already know *what* to do. They struggle with *when, where and how*, and repeated planning causes decision fatigue. This is a **planning friction** problem, not a motivation problem.

**Target user.** College students (17-25) who want consistency but struggle to plan. Hardcore procrastinators and already-disciplined users are out of scope.

**Product principles (non-negotiable)**
1. Minimum input from the user.
2. Maximum automation by the system.
3. Flexible, not rigid.
4. The system adapts; the user does not.

**Test for every decision:** if it increases the user's thinking effort, it is wrong.

**Differentiation.** Other apps are *tools* that help you plan better. AutoDay is a *decision engine* that removes planning.

---

## 2. Task Inputs

### Mandatory (3)

| Field | Notes |
|---|---|
| **Title** | Free text. |
| **Duration** | Minutes. |
| **Priority** | Urgent / Medium / Low. **Pre-selected to Medium**, so it costs zero taps unless changed. |

### Optional / collapsed (5)

| Field | Default | Notes |
|---|---|---|
| **Deadline** | None | A **hard** constraint. |
| **Fixed / Flexible** | Flexible | Fixed requires one extra field: **start time**. A fixed task is a blocked slot, not a scored task. |
| **Splittable** | Auto: **ON if duration ≥ 90 min**, else OFF | The toggle only overrides the default. |
| **Repeat** | None | Creates a template that generates instances. |
| **Preferred window** | None | A **soft** constraint: tried first, never blocks scheduling. |

> **Only two hard constraints exist:** Deadline and Fixed. Everything else is soft.

---

## 3. System Constants (not user-editable)

| Constant | Value | Purpose |
|---|---|---|
| Planning horizon | 7 days | How far ahead the scheduler plans. |
| Day bounds | From the user's wake/sleep time (set once) | No per-task input. |
| Buffer | 10 min after every task | Prevents back-to-back burnout and overruns. |
| Daily cap | 80% of free time | Enforces "avoid overbooking" and "spread overload". |
| Minimum chunk | 30 min | Smallest piece a split task can be cut into. |
| Frozen zone | In-progress tasks and tasks starting within 15 min | Never moved, so the schedule doesn't jitter under the user. |
| Slack window | 72 h | Scale for deadline pressure. |
| Snooze cap | Counts up to 3 | Bounds the starvation-prevention boost. |

These are fixed because every setting is a decision, and decisions are what the app removes.

---

## 4. When the Scheduler Runs

| Trigger | Action |
|---|---|
| Task added | Full re-run |
| Task edited | Full re-run |
| Snooze | `reschedule_count++`, exclude the task until the snooze time, re-run |
| Missed (end time passed, not Done) | Mark missed, `reschedule_count++`, re-run |
| New fixed task conflicts with a scheduled one | Re-run; the flexible task moves |
| Done | Free the slot, re-run (pulls tasks forward) |
| Day rollover | Re-run |

**Stability rule.** On every re-run, a task keeps its previous slot if that slot is still valid. Only tasks that *must* move are moved. Without this, every snooze reshuffles the whole day and users stop trusting the schedule.

---

## 5. The Algorithm

### Step 0: Build the timeline
1. Create free slots for the 7-day horizon, inside the day bounds.
2. Remove frozen-zone tasks from the free space.
3. Apply the 80% daily cap to each day's free time.

### Step 1: Place fixed tasks
- Fixed tasks become blocked slots. **They always win conflicts.**
- If two fixed tasks overlap, flag it once and keep both. That is the user's own conflict, not the system's to resolve.

### Step 2: Feasibility gate (deadline violation → BLOCK)

```
slack     = (deadline - now) - remaining_duration
available = free capacity between now and deadline

if available < remaining_duration → BLOCK
```

- A blocked task is **never scheduled**.
- Nothing else is silently dropped to make room.
- The user sees one line with two one-tap options: **Extend deadline** or **Shorten duration**.

### Step 3: Score flexible tasks

```
score = 0.40·P + 0.35·D + 0.15·S + 0.10·F
```

| Factor | Meaning | Formula |
|---|---|---|
| **P** | Priority | Urgent = 100, Medium = 60, Low = 30 |
| **D** | Deadline pressure (based on slack, not raw proximity) | `100 × (1 − clamp(slack / 72h, 0, 1))`; no deadline → 0 |
| **S** | Snooze / reschedule history | `min(reschedule_count, 3) × 25` (max 75) |
| **F** | Duration fit (shorter tasks get a bonus) | `100 × (1 − min(duration, 120) / 120)` |

**Why slack instead of deadline proximity?** A 3-hour task due in 4 hours is more urgent than a 20-minute task due in 2 hours. Slack captures that; raw proximity doesn't.

**Why S maxes at 75 (contributing about 11 points)?** It must be strong enough to stop a task being snoozed forever, but weak enough that a Low task can never overtake an Urgent one. Urgent has a 28-point lead over Low from priority alone (0.40 × 70).

**Sort order**
1. Tasks with **slack ≤ 0** go first (deadline overrides flexibility).
2. Then by **score**, descending.
3. Tie: **earliest deadline**, then **earliest created**.

### Step 4: Place each task, in sorted order
Try these in order. The first success wins.

| # | Attempt | Detail |
|---|---|---|
| 1 | **Preferred window** | Inside the window and before the deadline, in the tightest-fit gap (reduces fragmentation). |
| 2 | **Any gap before the deadline** | Window ignored; a window penalty is logged. |
| 3 | **Split** | Only if splittable. Fill the largest gaps with chunks of at least 30 min until the duration is covered. |
| 4 | **Next day with capacity** | Only if the deadline allows it (or there is no deadline). |
| 5 | **Displace** | Only if the task is Urgent or has slack ≤ 0: bump the lowest-score non-fixed, non-frozen placed task, then re-place the bumped task from attempt 1. |
| 6 | **BLOCK** | Same handling as Step 2. |

### Step 5: Spread overload
- Tasks with **slack > 24 h** are placed at their **latest feasible day minus 1**, not the earliest slot. This stops everything piling onto today.
- If a day still exceeds the cap, move its lowest-score tasks (slack > 24 h) to the next day with capacity.

### Step 6: Repeat tasks
- A repeat is a **template** that generates independent instances inside the horizon.
- Each instance is scheduled like any other task. A fixed repeat becomes a recurring blocked slot.
- A missed instance is **marked missed and not carried forward**. Otherwise a missed daily task becomes two tasks tomorrow, which creates a guilt spiral and overload.

---

## 6. Mandatory Edge Cases → Where They Are Handled

| Edge case | Handling |
|---|---|
| Equal score → earliest deadline wins | Step 3 sort order, tie-break rules |
| No space → move to next day | Step 4, attempt 4 |
| Long task → split | Step 4, attempt 3 (auto-ON at 90 min or more, 30 min minimum chunk) |
| Deadline violation → BLOCK | Step 2 gate and Step 4, attempt 6 |
| User overload → spread across days | Daily cap (Step 0) and Step 5 |
| Fixed vs flexible conflict → fixed wins | Step 1; flexible tasks move on re-run |
| Two fixed tasks overlap | Flag once, keep both |
| Missed repeat instance | Marked missed, not carried forward |

---

## 7. Worked Example

**Setup.** Monday, now = 10:00. Day bounds 08:00-22:00. Fixed lecture 14:00-15:30 (buffer to 15:40).
Free gaps today: **10:00-14:00** and **15:40-22:00**.

| Task | Duration | Priority | Deadline | Reschedule count |
|---|---|---|---|---|
| A: Submit assignment | 60 min | Urgent | Mon 13:00 | 0 |
| B: Study physics | 120 min | Medium | Wed 10:00 | 2 |
| C: Reply to emails | 20 min | Low | none | 0 |

**Scoring**

| Task | Slack | P | D | S | F | Score |
|---|---|---|---|---|---|---|
| A | 2 h | 100 | 97.2 | 0 | 50 | **≈ 79.0** |
| B | 46 h | 60 | 36.1 | 50 | 0 | **≈ 44.1** |
| C | none | 30 | 0 | 0 | 83.3 | **≈ 20.3** |

**Order:** A → B → C. No slack is ≤ 0, so no overrides apply.

**Placement**
- **A:** the only gap before 13:00 is 10:00-14:00, so A goes to **10:00-11:00**.
- **B:** slack is above 24 h, so Step 5 applies. The latest feasible day is Wednesday, so B is placed on **Tuesday** (for example 16:00-18:00), not today.
- **C:** no deadline; the tightest-fit gap after A is 11:10-14:00, so C goes to **11:10-11:30**.

**Home screen shows:** A, with Done / Snooze / Edit. Nothing else.

**Now the user snoozes A by 30 minutes.**
1. A's `reschedule_count` becomes 1 and it is excluded until 10:30.
2. Slack falls to 1.5 h, so D rises to about 97.9; S is now 25. A's score becomes about **83**.
3. Re-run: A goes to **10:30-11:30**.
4. C's old slot (11:10-11:30) now conflicts, so C moves to **11:40-12:00**.
5. B stays put on Tuesday (stability rule).

**Blocked example.** The user adds a 3-hour task due in 2 hours. The gate finds 2 h of capacity for 3 h of work, so it is **BLOCKED**. A banner appears: *"Not enough time before the deadline: Extend deadline / Shorten duration."* No other task is touched.

---

## 8. Architecture

**Pattern:** MVVM + Service Layer, event-driven.

| Layer | Responsibility |
|---|---|
| **UI** | Dumb. Renders state, sends user actions. **No business logic.** |
| **ViewModel** | Holds screen state, exposes `next_task` and the blocked banner. |
| **Services** | Scheduler, rescheduler, notification service, location service, insights service. **The scheduler lives here.** |
| **Data layer** | Local storage for Task, Task_Schedule, Task_Location. |
| **OS integrations** | Notifications, geofencing, background execution, calendar/clock. |

**Flow:** UI event (add / edit / snooze / done) → ViewModel → Scheduler service → new Task_Schedule → ViewModel state update → UI re-renders.

---

## 9. UI Contract

The scheduler exposes one value to the UI:

```
next_task = first slot with start >= now and status = pending
```

- The home screen shows **that task** with **Done / Snooze / Edit**.
- A single-line banner appears only if a task is BLOCKED.
- No dashboards, no time-block grid, no complex graphs.

---

## 10. Data Model

```
User:           id, wake_time, sleep_time

Task:           id, title, duration, priority (default MEDIUM),
                deadline?, is_fixed, fixed_start?, splittable,
                repeat_rule?, window_start?, window_end?,
                reschedule_count, status

Task_Schedule:  task_id, start, end, chunk_index, window_penalty

Task_Location:  task_id, lat, lng, radius, time_filter?
```

**Task status:** `pending`, `done`, `missed`, `snoozed`, `blocked`.

---

## 11. Supporting Features

### Notifications
- Every notification offers **Done / Snooze / Edit**.
- **Snooze triggers an instant reschedule** (Section 4).

### Location-based reminders
- Fire when the user arrives at the saved place, **only if the task is still pending**.
- Optional time filter.
- Use cases: library, submission desk, errands.

### Progress insights (lightweight)
- Track only: **completed, missed, snoozed, focus time**.
- No heavy graphs and no gamification.

---

## 12. Locked Decisions

| Decision | Status |
|---|---|
| Min chunk = 30 min | Locked. Not yet validated against survey data. |
| Daily cap = 80%, fixed | Locked. A setting would add a decision. |
| Priority defaults to Medium | Locked. |
| Splittable defaults to auto (≥ 90 min) | Locked. |
| Preferred window is soft | Locked. |
| Missed repeats are not carried forward | Locked. |
| Blocked tasks are never silently dropped or forced | Locked. |

## 13. Out of Scope for MVP
- User-adjustable weights, caps or buffers
- AI or ML-based prediction
- Gamification, streaks, heavy analytics
- Time-block grid or calendar-style UI
