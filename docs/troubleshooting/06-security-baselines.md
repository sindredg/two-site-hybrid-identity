# Phase 6. Security baselines

Walkthrough: [06-security-baselines.md](../06-security-baselines.md).

Two entries. The first is the baseline blocking the tool meant to measure it, which
is the most instructive thing that happened in this phase. The second is why the
measurement was done a different way.

---

## 1. The baseline blocks Policy Analyzer from running

**Symptom.** `PolicyAnalyzer.exe` on CL01 shows the SmartScreen dialog with no way to
continue. The same file on CL02 offers a **Run** button.

```
SmartScreen can't be reached right now
Microsoft Defender SmartScreen is unreachable and can't help you decide if this app
is ok to run.
```

**Cause.** The baseline sets SmartScreen to warn and prevent bypass. On a machine that
cannot reach the SmartScreen reputation service, the setting fails closed and removes
the override. CL02 has no such policy, so it fails open.

Confirmed rather than assumed:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name EnableSmartScreen, ShellSmartScreenLevel -ErrorAction SilentlyContinue
```

`ShellSmartScreenLevel : Block` is the value removing the button.

**Resolution applied.** SmartScreen only inspects files carrying Mark of the Web, the
alternate data stream added on download. Removing it from the specific binary means
SmartScreen is never consulted, and the policy stays intact:

```powershell
Get-ChildItem C:\PolicyAnalyzer_40 -Recurse | Unblock-File
```

**Rejected: disabling the setting.** It would have worked and it would have been
wrong twice over. The lab would lose a control it had just deployed, and the machine
would no longer represent the baseline being measured, which invalidates the
comparison the phase exists for. Stripping MOTW from one deliberately downloaded
Microsoft-signed binary is a decision with a boundary. Turning off SmartScreen
estate-wide to run one tool is the kind of shortcut that becomes permanent.

**Worth keeping.** This is the clearest illustration in the lab of what a baseline is
for and what it costs. The setting did exactly its job, and its job was inconvenient.

---

## 2. Policy Analyzer could not carry the comparison

**Symptom.** Not an error. A sequence of friction that added up to the tool being the
wrong instrument.

**What was hit, in order.**

Explorer's archive browsing produces paths like
`C:\Users\...\Downloads\Baseline.zip\Windows Server-2022-Security-Baseline-FINAL\GPOs`
that look real and cannot be read by anything outside Explorer:

```
Error: directory doesn't exist:
C:\SCT\Baseline\Windows Server-2022-Security-Baseline-FINAL\GPOs\{GUID}
```

Policy Analyzer is also a separate download from the baseline packs on the same page,
so the baseline zip alone does not contain it.

**The structural problem.** The tool runs on the endpoint being measured. Comparing
CL01 against CL02 means deploying it to both, which on a hardened CL01 runs into entry
1. Building the rules file is scriptable with `GPO2PolicyRules.exe`:

```powershell
& "C:\PolicyAnalyzer_40\GPO2PolicyRules.exe" $gpoBackupFolder "C:\SCT\MemberServer.PolicyRules"
```

The comparison and the export are not.

**Resolution applied.** Group Policy Modeling instead. It runs on the domain
controller, needs nothing installed on either client, names the winning GPO for every
setting, and produces HTML rather than a spreadsheet.

**Lesson.** The evidence a phase needs and the tool a phase started with are separate
choices. Modeling answered "what does the baseline change here, and which GPO won"
directly, which is the actual question. Persisting with Policy Analyzer would have
produced the same answer more slowly and in a worse format.
