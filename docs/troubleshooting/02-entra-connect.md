# Phase 2. Entra Connect Sync

Walkthrough: [02-entra-connect.md](../02-entra-connect.md).

A Windows Server default that blames the wrong layer, a refusal that was correct,
and one thing still unexplained.

---

## 1. Entra Connect sign-in blocked by Internet Explorer ESC

The Entra sign-in step inside the Connect Sync wizard failed to load.

```
Content within this application coming from the website listed below is being
blocked by Internet Explorer Enhanced Security Configuration.
https://login.microsoftonline.com
```

![IE ESC blocking the sign-in](../images/phase2/ie-esc-blocked.png)

Then, on the sign-in page itself:

```
We can't sign you in
JavaScript is required to sign in. Your browser either does not support
JavaScript or it is being blocked.
```

![JavaScript is required to sign in](../images/phase2/javascript-blocked.png)

**Cause.** The visible error blames JavaScript. The actual cause is **Internet
Explorer Enhanced Security Configuration**, on by default on Windows Server, which
strips scripting from untrusted zones. The Connect Sync wizard uses an embedded
browser control and inherits that policy.

**Resolution applied.** Disabled ESC for Administrators, then relaunched:

```powershell
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' -Name IsInstalled -Value 0
Stop-Process -Name Explorer -Force
```

**Restarting Explorer is not enough on its own.** The wizard is a separate process
and reads zone settings at launch, so it must be closed and reopened. That detail
cost a round of "the fix did not work".

**Re-enable it afterwards.** Set the value back to `1`. ESC was disabled for an
installer, not permanently, and a sync server is not the place to leave it off.
Done in [Phase 5](../05-group-policy.md), where the same command run on DC01 first
fails, because Server Core has no Internet Explorer for the setting to apply to.

**Lesson.** The error names the symptom two layers below the cause. Same shape as
the Group Policy Client hang, where the message named `gpsvc` and the cause was
`SysvolReady = 0`.

---

## 2. Connect Sync refuses a Domain Admin as the connector account

Supplying an existing Domain Admin on the AD forest account dialog
was rejected outright.

![AD forest account with a Domain Admin](../images/phase2/ad-forest-existing-account.png)

```
Using an Enterprise or Domain administrator account for your AD forest account is
not allowed. Let Microsoft Entra Connect Sync create the account for you or
specify a synchronization account with the correct permissions.
```

![Domain admin rejected](../images/phase2/domain-admin-rejected.png)

**Cause.** Not a bug. Two credentials were being conflated:

| Credential | Used | Stored |
|---|---|---|
| Enterprise Admin | Once, to create things | Never |
| AD DS connector account | Every 30 minutes, forever | On the sync server |

If the sync server is compromised, a stored Domain Admin credential hands over the
forest. A stored `MSOL_` credential hands over directory read access. Connect Sync
will not let you make that mistake.

**Resolution applied.** Selected **Create new AD account** and supplied the
Enterprise Admin credential there instead. The wizard mints `MSOL_<hash>` with
Replicate Directory Changes and Replicate Directory Changes All, and nothing else.

**Lesson.** The installer enforced least privilege before the lab got round to it.
The same pattern the risk register flags for `labadmin` is what Phase 8 exists to
fix.

---

## 3. UPN suffix shows "Not Added" for a domain that is verified

**Phase 2. Unresolved.** The Microsoft Entra sign-in configuration page reported
both UPN suffixes as unmatched.

![Both suffixes showing Not Added](../images/phase2/upn-suffix-not-added.png)

**`sindredg.local` showing Not Added is correct and permanent.** A `.local` suffix
can never be verified in Entra, because ownership is proved with a public DNS TXT
record and `.local` has no public DNS. That is why Phase 1 retargeted the users
onto the onmicrosoft suffix in the first place.

**`<tenant>.onmicrosoft.com` showing Not Added is wrong.** Queried
directly against Graph, outside the wizard:

```
<tenant>.onmicrosoft.com   Verified: True   Default: True   Initial: True
```

**Cause: unknown.** Refreshing the page did nothing. Re-authenticating did
nothing. The best remaining hypothesis is that the token was obtained while ESC
was blocking JavaScript, but the wizard offers no way to inspect it. Recorded as
unexplained rather than given an invented cause.

**Resolution applied.** Ticked "Continue without matching all UPN suffixes to
verified domains" and proceeded, on the reasoning that the display was wrong
rather than the tenant:

- All five synced users are already on the onmicrosoft suffix
- That domain is verified, per Graph
- The only accounts still on `@sindredg.local` are outside `OU=Sync` and never sync
- The outcome is cheap to verify afterwards and cheap to correct

**Confirmed correct after the fact.** All five users synced with
`@<tenant>.onmicrosoft.com` intact. The wizard was displaying
something untrue and nothing else was wrong.

**Lesson.** When a tool disagrees with the system, check the system. Proceeding on
a Graph query rather than a dialog was the right call, and the verification step
afterwards is what made it a safe call rather than a lucky one.
