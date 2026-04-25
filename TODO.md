# A2DP2FM TODO - Prioritized Task Breakdown

**Total Effort:** ~43.5 hours (original Bluetooth scope) | **Timeline:** ~1.3 weeks

## Completed Features (outside original scope)

- ✅ **AirPlay -> FM pathway** (`airplay2fm.sh`) — shairport-sync pipe backend → PiFmRds, RDS metadata from shairport-sync metadata pipe, LED status, systemd services, tmpfiles.d FIFO persistence.
- ✅ **Dedicated uninstall script** (`uninstall.sh`) — detects both installs, interactive menu, smart shared-resource handling, `--bt`/`--airplay`/`--all`/`--yes` flags.

---

## 🔴 PHASE 1: ROBUSTNESS (Critical Fixes - Week 1)
*Prevents silent failures and data corruption*

### Task #1: Validate PiFmRds binary after build before starting service
- **Priority:** Critical
- **Impact:** High - Silent build failures currently go undetected
- **Effort:** 2 hours
- **File(s):** a2dp2fm.sh (install_bluealsa_from_source section, after make)
- **Implementation:**
  - Add `pi_fm_rds --version` check after build completes
  - Add test transmission on GPIO4 (1 second burst)
  - Fail loudly if binary validation fails
  - Log binary path and version to INSTALL_SUMMARY
- **Testing:** Verify with intentional build failure to ensure error is caught
- **Status:** ⬜ Pending

### Task #2: Add GPIO4 pin conflict detection and warning
- **Priority:** Critical
- **Impact:** High - Crashes with other services using GPIO4
- **Effort:** 2 hours
- **File(s):** a2dp2fm.sh (new check_required_commands function area)
- **Implementation:**
  - Check `/sys/class/gpio/gpio4` doesn't exist or is writable
  - Scan dmesg for GPIO4 allocation errors
  - Check for gpio-fan, gpio-led overlays claiming pin 4
  - Add to preflight checks before uninstall/install
- **Testing:** Test with gpio-fan overlay enabled, should warn/fail
- **Status:** ⬜ Pending

### Task #4: Add audio quality auto-failsafe with bitrate downsampling
- **Priority:** Critical
- **Impact:** Medium - Stutter requires manual intervention
- **Effort:** 2 hours
- **File(s):** bt2fm.sh (embedded in a2dp2fm.sh heredoc)
- **Implementation:**
  - Detect arecord underrun/stall (XRUN messages)
  - Auto-retry with `-r 32000` on first failure
  - Auto-retry with `-r 22050` on second failure
  - Log each downgrade with timestamp
  - Add counter to prevent infinite retries
- **Testing:** Simulate slow Pi, verify graceful degradation
- **Status:** ⬜ Pending

### Task #5: Enforce frequency range bounds at runtime in bt-volume-freqd.sh
- **Priority:** Critical (data integrity)
- **Impact:** Low - Edge case but prevents invalid state
- **Effort:** 1 hour
- **File(s):** bt-volume-freqd.sh (embedded in a2dp2fm.sh)
- **Implementation:**
  - Add bounds check before `sed -i` write to /etc/default/bt2fm
  - Verify new_freq >= FMIN and <= FMAX
  - Log if value was clamped
  - Prevent out-of-band frequencies from manual edits
- **Testing:** Manually edit /etc/default/bt2fm with invalid freq, verify it gets corrected
- **Status:** ⬜ Pending

### Task #3: Implement RDS FIFO error recovery and health checks
- **Priority:** Critical (reliability)
- **Impact:** Medium - Metadata silently fails
- **Effort:** 3 hours
- **File(s):** avrcp_rds.py (embedded in a2dp2fm.sh), new systemd timer
- **Implementation:**
  - Replace silent `except: pass` with logging + retry logic
  - Implement exponential backoff (1s, 2s, 4s, 8s, max 30s)
  - Add healthcheck script that verifies /run/rds_ctl is FIFO
  - Create systemd timer to check FIFO health every 60s
  - Auto-restart avrcp-rds.service if FIFO missing
- **Testing:** Delete /run/rds_ctl, verify it's recreated and service restarts
- **Status:** ⬜ Pending

**Phase 1 Subtotal: 10 hours** ✓ Completable in 1-2 days

---

## 🟠 PHASE 2: QUALITY & FEATURES (High Priority - Week 2)
*Improves user experience and reliability*

### Task #6: Upgrade TTS quality with sox post-processing
- **Priority:** High
- **Impact:** High - User-facing audio quality
- **Effort:** 3 hours
- **File(s):** fm_announce.sh (embedded in a2dp2fm.sh)
- **Implementation:**
  - Keep pico2wave as primary (better prosody)
  - Fallback to espeak-ng with: `-s 130 -p 60` (slower, pitched)
  - Add sox post-processing pipeline:
    - `norm -3` (normalize to -3dB headroom)
    - `dcshift -0.1` (remove DC offset)
    - `compand 0.05,0.1 -60,-60,-20,-20,-10,-10,0,0` (FM compression)
  - Create `say_hq()` helper function
  - Update APT_PACKAGES to include `sox`
- **Testing:** Test both pico2wave and espeak-ng paths, compare audio quality
- **Status:** ⬜ Pending

### Task #9: Add frequency step size validation (FCC compliance)
- **Priority:** High
- **Impact:** Medium - Regulatory compliance
- **Effort:** 1.5 hours
- **File(s):** a2dp2fm.sh (argument validation section)
- **Implementation:**
  - FCC: Allow only 200 kHz steps (0.2 MHz)
  - EU: Allow 100 kHz steps (0.1 MHz)
  - Default to warning mode (log but allow)
  - Add `--enforce-fcc` flag for strict mode
  - Validate both STEP and actual frequency boundaries
- **Testing:** Test --step 0.05 (should warn), --step 0.2 (should pass)
- **Status:** ⬜ Pending

### Task #7: Add TTS language/voice selection option
- **Priority:** High
- **Impact:** Low - Localization
- **Effort:** 1.5 hours
- **File(s):** fm_announce.sh (embedded in a2dp2fm.sh)
- **Implementation:**
  - Add environment variable: `A2DP2FM_TTS_LANG` (default: en-US)
  - Support: en-US, en-GB, es-ES, fr-FR, de-DE (pico2wave)
  - Support same for espeak-ng with fallback
  - Store selected language in /etc/default/bt2fm
  - Update announcements to say language name
- **Testing:** Test --lang es-ES, verify Spanish announcements
- **Status:** ⬜ Pending

### Task #8: Add BlueALSA device selection capability
- **Priority:** High
- **Impact:** Low - Multi-adapter systems
- **Effort:** 1.5 hours
- **File(s):** a2dp2fm.sh (bluealsa_daemon_path function and bt2fm.sh)
- **Implementation:**
  - Add `A2DP2FM_BT_DEVICE` environment variable
  - Show available devices with `hciconfig -a` in --dry-run
  - Allow specifying by MAC or hci index
  - Update bt2fm.sh to use specified device for arecord
  - Store selection in /etc/default/bt2fm
- **Testing:** Test with multiple BT adapters, specify each one
- **Status:** ⬜ Pending

### Task #22: Create comprehensive integration test suite
- **Priority:** High
- **Impact:** Medium - Catch regressions
- **Effort:** 4 hours
- **File(s):** tests/run-install-test.sh (expand existing)
- **Implementation:**
  - Add GPIO4 validation test (check sysfs)
  - Add PiFmRds binary test (--version check)
  - Add BlueALSA startup check (arecord -L)
  - Add RDS FIFO creation verification
  - Add systemd service health checks
  - Add audio pipeline connectivity test (mock audio through pipeline)
  - Generate coverage report showing % of code tested
- **Testing:** Run full test suite, verify all new checks pass
- **Status:** ⬜ Pending

### Task #10: Update AGENTS.md with TTS customization guidance
- **Priority:** High
- **Impact:** Medium - Developer guidance
- **Effort:** 2 hours
- **File(s):** AGENTS.md (new section)
- **Implementation:**
  - Add "## TTS Customization" section
  - Document voice parameters: speed, pitch, amplitude
  - Explain quality vs intelligibility tradeoffs
  - Provide sox post-processing examples
  - Document language selection method
  - Add troubleshooting: "My voice sounds robotic" → solutions
- **Testing:** Have another developer read it and provide feedback
- **Status:** ⬜ Pending

### Task #11: Update AGENTS.md with frequency regulation compliance notes
- **Priority:** High
- **Impact:** Medium - Legal/safety
- **Effort:** 2 hours
- **File(s):** AGENTS.md (new section)
- **Implementation:**
  - Add "## Regulatory Compliance" section
  - Document FCC rules (US), ETSI (EU), other regions
  - Power limits and antenna regulations
  - Step size requirements per region
  - Legal disclaimer
  - Link to regulatory references
- **Testing:** Verify links are current and accurate
- **Status:** ⬜ Pending

### Task #12: Add troubleshooting methodology to AGENTS.md
- **Priority:** High
- **Impact:** Medium - Support & debugging
- **Effort:** 2.5 hours
- **File(s):** AGENTS.md (new section)
- **Implementation:**
  - Create decision tree for common issues:
    - No audio → check BlueALSA, arecord, bt2fm.service
    - LED not responding → check GPIO17, ledctl.sh
    - Frequency stuck → check bt-volume-freqd.service
    - RDS missing → check avrcp-rds.service, FIFO
    - BT won't pair → check bt-setup.service, bluetooth.service
  - For each: diagnostic commands, expected output, fixes
  - Add systemctl status examples
  - Document journalctl log reading
- **Testing:** Walk through each troubleshooting path
- **Status:** ⬜ Pending

**Phase 2 Subtotal: 18 hours** ✓ Completable in 2-3 days

---

## 🟡 PHASE 3: DOCUMENTATION & UX (Medium Priority - Week 2-3)
*Makes system more usable and maintainable*

### Task #13: Update README.md with audio quality tuning section
- **Priority:** Medium
- **Impact:** Low - User education
- **Effort:** 1.5 hours
- **File(s):** README.md (new section after "Troubleshooting")
- **Implementation:**
  - Add "## Audio Quality Tuning" section
  - Explain TTS improvements (sox, pico2wave vs espeak-ng)
  - Document how to adjust parameters: speed, pitch, compression
  - Explain FM de-emphasis and why it matters
  - Provide before/after audio examples (or links)
  - Add headphone test procedure
- **Testing:** Verify all example commands work
- **Status:** ⬜ Pending

### Task #14: Add performance tuning guidelines to AGENTS.md
- **Priority:** Medium
- **Impact:** Low - Expert users
- **Effort:** 1.5 hours
- **File(s):** AGENTS.md (new section)
- **Implementation:**
  - Document audio buffer sizes and where to tune
  - CPU load monitoring: `top -p $(pidof bluealsad)`
  - Systemd resource limits (CPUQuota, MemoryLimit)
  - Pi3 vs Pi4 performance differences
  - Identify bottlenecks: CPU vs IO vs memory
  - Profiling procedure
- **Testing:** Profile on both Pi3 and Pi4
- **Status:** ⬜ Pending

### Task #15: Create uninstall verification checklist
- **Priority:** Medium
- **Impact:** Low - Operational safety
- **Effort:** 1 hour
- **File(s):** AGENTS.md (new section or standalone UNINSTALL.md)
- **Status:** ✅ Done — superseded by `uninstall.sh`, which scans system state before and after removal and prints a summary of every removed artifact.

### Task #16: Add BlueALSA health monitoring and auto-recovery
- **Priority:** Medium
- **Impact:** Medium - Reliability
- **Effort:** 3 hours
- **File(s):** New script /usr/local/bin/bluealsa-healthd.sh, new systemd timer
- **Implementation:**
  - Create healthcheck script that tests bluealsad is running
  - Test audio device availability: `arecord -L | grep bluealsa`
  - Create systemd timer (every 60s)
  - Auto-restart bluealsad if missing
  - Log health status to journalctl
  - Add restart counter to prevent infinite loops
- **Testing:** Kill bluealsad, verify it auto-restarts within 60s
- **Status:** ⬜ Pending

### Task #17: Add antenna impedance/SWR guidance to README
- **Priority:** Medium
- **Impact:** Low - RF engineering education
- **Effort:** 1.5 hours
- **File(s):** README.md (update "Antenna" section)
- **Implementation:**
  - Explain 1/4-wave antenna: ~82 cm at 100 MHz
  - Explain 1/2-wave antenna: ~164 cm
  - Why 10-20 cm is compromise (broadband but inefficient)
  - Explain SWR (Standing Wave Ratio) and impedance matching
  - Add ASCII diagram of antenna options
  - Mention ferrite choke for ground isolation
  - Link to antenna calculators
- **Testing:** Verify antenna calculations are correct
- **Status:** ⬜ Pending

### Task #18: Implement test mode without requiring Bluetooth device
- **Priority:** Medium
- **Impact:** Low - Development/CI
- **Effort:** 2 hours
- **File(s):** a2dp2fm.sh, new test-audio-generator script
- **Implementation:**
  - Add `A2DP2FM_TEST_MODE=1` environment variable
  - Create dummy audio source (sine wave generator)
  - Bypass BlueALSA requirement
  - Allow full system validation without phone pairing
  - Useful for CI/CD and headless testing
  - Add to --dry-run output
- **Testing:** Run with TEST_MODE=1, verify audio flows through system
- **Status:** ⬜ Pending

### Task #20: Add service dependency graph documentation
- **Priority:** Medium
- **Impact:** Low - Maintenance
- **Effort:** 1.5 hours
- **File(s):** AGENTS.md or new ARCHITECTURE.md
- **Implementation:**
  - Create ASCII diagram showing service dependencies
  - Show data flow: Bluetooth → BlueALSA → bt2fm → PiFmRds
  - Show control flow: Volume → bt-volume-freqd → PiFmRds
  - Show metadata flow: AVRCP → avrcp_rds → RDS FIFO
  - Show status flow: Services → led-statusd → LED
  - Document each service's role and restart behavior
- **Testing:** Verify diagram matches actual systemd dependencies
- **Status:** ⬜ Pending

**Phase 3 Subtotal: 12 hours** ✓ Completable in 2-3 days (some parallelizable)

---

## 🟢 PHASE 4: POLISH & OPTIMIZATION (Low Priority - Optional)
*Nice-to-have enhancements*

### Task #19: Create systemd socket activation option for services
- **Priority:** Low
- **Impact:** Low - Resource optimization
- **Effort:** 2 hours
- **File(s):** New /etc/systemd/system/bt2fm.socket, etc
- **Implementation:**
  - Create socket activation configs for bt2fm, avrcp-rds
  - Services start on-demand instead of at boot
  - Saves Pi memory/CPU when not in use
  - Make optional via `A2DP2FM_LAZY_START=1`
  - Document socket activation in AGENTS.md
- **Testing:** Verify services don't start until socket is accessed
- **Status:** ⬜ Pending

### Task #21: Implement systemd journal log aggregation helper
- **Priority:** Low
- **Impact:** Low - Debugging UX
- **Effort:** 1.5 hours
- **File(s):** New helper script /usr/local/bin/a2dp2fm-status
- **Implementation:**
  - Create shell command `a2dp2fm-status` that shows:
    - All service statuses (systemctl status a2dp2fm.*)
    - Recent errors from journalctl
    - Current frequency and settings
    - GPIO4 status
    - Bluetooth device status
  - Make it equivalent to running 10+ diagnostic commands
  - Color output for easy scanning
- **Testing:** Run command, verify all info is current and useful
- **Status:** ⬜ Pending

**Phase 4 Subtotal: 3.5 hours** ✓ Optional polish

---

## 📈 COMPLETION TRACKING

| Phase | Tasks | Hours | Priority | Status |
|-------|-------|-------|----------|--------|
| 1: Robustness | 5 | 10h | 🔴 Critical | ⬜ Not Started |
| 2: Quality | 8 | 18h | 🟠 High | ⬜ Not Started |
| 3: Documentation | 7 | 12h | 🟡 Medium | ⬜ Not Started |
| 4: Polish | 2 | 3.5h | 🟢 Low | ⬜ Not Started |
| **TOTAL** | **22** | **43.5h** | — | **0% Complete** |

---

## 🎯 MILESTONE DEFINITIONS

**Milestone 1 (Robustness):** All Phase 1 tasks complete
- Result: Script is resilient and fails loudly on errors

**Milestone 2 (Production-Ready):** Phases 1 + 2 complete
- Result: High-quality audio, better UX, comprehensive tests

**Milestone 3 (Well-Documented):** Phases 1 + 2 + 3 complete
- Result: Easy for others to modify, debug, and extend

**Milestone 4 (Optimized):** All phases complete (optional)
- Result: Resource-efficient, fully polished

---

## 📝 NOTES

- Tasks can be parallelized within phase (docs don't block code)
- Each task includes implementation details and testing criteria
- Effort estimates are for experienced bash/systemd developer
- Est. 1-2 hours per task for experienced contributor
- Comments welcome on difficulty or scope changes
