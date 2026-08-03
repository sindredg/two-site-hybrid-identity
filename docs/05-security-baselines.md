# Phase 5. Security baselines

> **Status: Pending.** Not yet executed. Written from documented behaviour, to be
> rewritten as a record with screenshots once run.

**Goal:** apply Microsoft's own hardening guidance and measure the difference,
rather than applying it and asserting an improvement.

> Uses the
> [Microsoft Security Compliance Toolkit](https://learn.microsoft.com/windows/security/operating-system-security/device-management/windows-security-configuration-framework/security-compliance-toolkit-10),
> downloaded onto CS01.

**Why this matters.** "Hardened" is a claim. A Policy Analyzer comparison between a
baselined machine and an untouched one is evidence. The two clients exist for
exactly this.

---

## 1. What the toolkit contains

| Component | Purpose |
|---|---|
| Baseline GPO backups | Microsoft's recommended settings, shipped as importable GPOs rather than as code |
| Policy Analyzer | Compares policy sets and highlights differences and conflicts |
| LGPO.exe | Applies local policy, useful on machines outside a domain |

Microsoft distributes these as GPO backups, not in any machine-readable
configuration format. That is a real limitation and the reason this layer is not
IaC in the way the Azure footprint is.

---

## 2. Method

1. Download the toolkit and the Windows Server 2022 member server baseline
2. Import the baseline as a GPO with `Import-GPO`
3. Link it to `OU=Workstations`, security-filtered to **CL01 only**
4. Leave CL02 receiving only the Phase 4 policy, as the control
5. Run Policy Analyzer against both and export the comparison

CL01 hardened, CL02 untouched, everything else identical. That isolates the
baseline as the only variable.

---

## 3. The interesting part is what breaks

A baseline applied wholesale to a lab will disable something the lab needs.
Candidates worth watching in this environment:

| Setting area | Likely effect here |
|---|---|
| NTLM restrictions | Can interfere with access between member servers |
| Interactive logon and RDP hardening | Bastion sessions are RDP, so this is the one that could lock you out |
| Windows Firewall profiles | Baseline profiles may override rules the lab depends on |
| Legacy protocol removal | Usually desirable, occasionally load-bearing |

**Test on CL01 before applying anywhere else**, and keep a Bastion session open on
CL02 while doing it. Locking yourself out of the machine you are hardening is the
classic way this phase goes wrong.

Each exception made to the baseline gets recorded in `decisions.md` with its
reason. A baseline applied with documented exceptions is a defensible position; a
baseline applied blindly is not.

---

## 4. Exit criteria

| Criterion | Status |
|---|---|
| Toolkit installed on CS01 | Pending |
| Baseline imported and linked, filtered to CL01 | Pending |
| CL02 confirmed unaffected as the control | Pending |
| Policy Analyzer comparison exported and committed | Pending |
| Every deviation from the baseline recorded with a reason | Pending |

---

## Next

[Phase 6](06-windows-laps.md) removes the shared local administrator password,
using the Group Policy estate from Phase 4 and the hybrid join from Phase 3.
