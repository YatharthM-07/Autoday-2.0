<div align="center">

# ⚡ A U T O D A Y ⚡

### 🗓️ *Your Day, Automatically Planned.*

**The decision engine that plans your day, so you don't have to.**

![Platform](https://img.shields.io/badge/Platform-iOS-black?style=for-the-badge&logo=apple)
![Language](https://img.shields.io/badge/Swift-UIKit-orange?style=for-the-badge&logo=swift)
![Architecture](https://img.shields.io/badge/Architecture-MVVM%20%2B%20Services-blue?style=for-the-badge)
![Focus](https://img.shields.io/badge/Zero-Planning%20Effort-success?style=for-the-badge)

</div>

---

> **AutoDay is not a task manager. It is a system that decides your day for you.**

---

## 🎯 The Problem
- Students already know *what* they need to do, but struggle with *when* and *how*.
- Repeated daily planning causes decision fatigue.
- This is **not a motivation problem**. It is a **planning friction problem**.
- Existing apps help you plan better. AutoDay makes planning unnecessary.

## 👥 Target Users
College students (about 17–25) who want consistency but struggle to plan their day.

## 🧭 Product Principles
- Minimum input, maximum automation
- Flexible, not rigid: the system adapts, the user doesn't
- Always show "what to do next" clearly
- No clutter, no guilt-based notifications, no gamification

---

## ✨ Features (Current Version)

| Feature | What it does |
|---|---|
| **Minimal Task Input** | Only title and duration are required. Deadline, priority, and fixed time are optional. |
| **Auto-Scheduling Engine** | Scores tasks (priority + deadline proximity + duration fit + reschedule history) and places them into free slots. |
| **Smart Rescheduling** | Snooze, miss, or add a task and the whole day is recalculated automatically. |
| **Task Splitting** | Long tasks are split into chunks so fragmented free time becomes usable. |
| **Action Notifications** | Done / Snooze / Edit straight from the notification. Snooze triggers instant rescheduling. |
| **Lightweight Insights** | Completed, missed, snoozed, and focus time. No heavy graphs. |

### 📐 Scheduling Rules
- High priority first; **deadlines override flexibility**
- Fixed tasks always win conflicts; low-priority tasks move
- Equal score → earliest deadline wins
- No space → move to next day
- Long task → split
- Deadline violation → block scheduling and warn
- Overload → spread across days

---

### 🔀 Three Ways a Task Gets Scheduled
1. **Manual Placement:** the task goes to the Unscheduled list and you drag it in.
2. **Full Auto-Schedule:** the task is scored and placed instantly.
3. **Organize My Day:** one tap cleans up and re-sorts the whole timeline.

*Fixed-time tasks always bypass all three and go straight to their slot.*

### 🔄 Task Lifecycle
`Unscheduled → Scheduled (Fixed / Auto-placed / Manually placed) → Completed | Missed → Needs Rescheduling → Rescheduled`

---

## 🏗️ Architecture

**MVVM + Service Layer**, event-driven.

```
UI (dumb views)  →  ViewModel (state)  →  Services (all logic)  →  Data layer
                                                  ↓
                                         OS integrations
```

- **No business logic in the UI.** The scheduler lives in the service layer.
- OS features (notifications) are reached only through services.
- MVVM was chosen over MVC to keep scheduling and background triggers out of ViewControllers.

### 🗂️ Data Model
`User` · `UserPreferences` · `Task` · `Task_Schedule`
Key fields: priority, deadline, duration, rescheduleCount, isFixed, isAutoScheduled, isManuallyPlaced

---

## 🛠️ Tech Stack

| Tech | Used for |
|---|---|
| **Swift** | Language |
| **UIKit** | Timeline UI, gestures, drag interactions |
| **Combine** | Reactive ViewModel → UI updates |
| **Core Data** | Local persistence of tasks, schedules, and insights |
| **UserNotifications** | Actionable reminders (Done / Snooze / Edit) |
| **Foundation + Codable** | Dates, scheduling math, serialization |
| **UserDefaults** | Lightweight preferences (scheduling mode, working hours) |
| **Xcode + Git/GitHub** | Development and version control |

Native Apple frameworks only, with no third-party dependencies, for reliability and simplicity.

---

## 🔒 Privacy & Ethics
- Local-first data
- No guilt-based notifications, no forced upgrades
- User stays in control of their schedule

## 💼 Business Model
Freemium. Core scheduling is free; optional premium features such as advanced insights and custom scheduling controls.

---

<div align="center">

## 👨‍💻 Meet the Team

### 🎓 Graphic Era University (GEU)

<table>
  <tr>
    <td align="center" width="25%">
      <h3>👑<br>Archita Saxena</h3>
      <i>Team SPOC</i>
    </td>
    <td align="center" width="25%">
      <h3>💡<br>Purvanshi Girdhar</h3>
      <i>Team Member</i>
    </td>
    <td align="center" width="25%">
      <h3>💡<br>Vetsa Sai Sardhik</h3>
      <i>Team Member</i>
    </td>
    <td align="center" width="25%">
      <h3>💡<br>Yatharth Mishra</h3>
      <i>Team Member</i>
    </td>
  </tr>
</table>

<br>

**Built with ❤️ to give students their time and focus back.**

*⚡ AutoDay: Your Day, Automatically Planned. ⚡*

</div>
