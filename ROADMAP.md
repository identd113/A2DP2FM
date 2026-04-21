# A2DP2FM Project Roadmap

## Vision
Transform A2DP2FM from a working prototype into a production-grade, well-documented, and maintainable Bluetooth-to-FM bridge system with high-quality audio and excellent reliability.

---

## 📅 Timeline

### Q1 2024: Foundation & Robustness
**Goal:** Make the system bulletproof and fail-safe

**Week 1-2: Critical Fixes**
- ✓ Validate PiFmRds builds correctly
- ✓ Detect GPIO4 conflicts early
- ✓ Auto-failsafe on audio underruns
- ✓ Enforce frequency bounds
- ✓ RDS FIFO error recovery

**Deliverable:** Resilient installer, no silent failures

---

### Q1 2024: Quality & Usability
**Goal:** Professional-grade audio and user experience

**Week 2-3: Audio Quality**
- ✓ Upgrade TTS with sox post-processing
- ✓ Add language/voice selection
- ✓ Add device selection (multi-adapter)
- ✓ Frequency step validation (FCC compliance)
- ✓ Comprehensive test suite

**Deliverable:** Studio-quality voice announcements, better hardware compatibility

---

### Q1 2024: Documentation
**Goal:** Enable community contributions and maintenance

**Week 3-4: Complete Documentation**
- ✓ AGENTS.md: TTS tuning guide
- ✓ AGENTS.md: Regulatory compliance
- ✓ AGENTS.md: Troubleshooting methodology
- ✓ README: Audio quality tuning
- ✓ README: Antenna guidance
- ✓ Service dependency graph

**Deliverable:** Clear path for debugging, extending, and deploying

---

### Q2 2024: Optimization (Optional)
**Goal:** Resource efficiency and polish

- ✓ Systemd socket activation
- ✓ Health monitoring automation
- ✓ Performance tuning guides
- ✓ Status aggregation helper

**Deliverable:** Lean, efficient system with diagnostic tools

---

## 🎯 Key Milestones

### Milestone 1: "Robust" ✓ Phase 1
**Status:** Ready for production use  
**When:** End of Week 1  
**Metrics:**
- ✅ No silent build/startup failures
- ✅ GPIO conflicts detected
- ✅ Graceful audio degradation
- ✅ All systemd services restart cleanly

### Milestone 2: "Professional" ✓ Phases 1 + 2
**Status:** Broadcast-ready audio quality  
**When:** End of Week 2  
**Metrics:**
- ✅ Studio-quality voice announcements
- ✅ Multi-language support
- ✅ FCC-compliant frequency stepping
- ✅ 100+ integration test cases passing

### Milestone 3: "Documented" ✓ Phases 1 + 2 + 3
**Status:** Community-ready  
**When:** End of Week 3-4  
**Metrics:**
- ✅ Troubleshooting flowchart complete
- ✅ Regulatory guidance clear
- ✅ Performance tuning documented
- ✅ New developers can onboard in 1 hour

### Milestone 4: "Optimized" ✓ All Phases (Optional)
**Status:** Production-hardened  
**When:** Q2 2024 (if prioritized)  
**Metrics:**
- ✅ Resource usage minimized
- ✅ Auto-recovery for all services
- ✅ Single-command diagnostics
- ✅ <100ms startup latency

---

## 📊 Effort Summary

```
Phase 1: Robustness      ████████░░  10h   Week 1
Phase 2: Quality         ██████████████████  18h   Week 2-3
Phase 3: Documentation   ████████████░░░░░░  12h   Week 3-4
Phase 4: Polish          ██░░░░░░░░░░░░░░░░  3.5h  Q2 (opt)
                         ─────────────────────────────
TOTAL:                   ██████████████████  43.5h
```

---

## 🏗️ Architecture Evolution

### Current State (v1.0)
```
Phone (A2DP)
    ↓
BlueALSA (daemon)
    ↓
bt2fm.sh (arecord piped to pi_fm_rds)
    ↓
PiFmRds (FM on GPIO4)
    ↓
Radio (88-108 MHz)
```

### After Phase 1: Robustness
```
[Validation]
    ↓
Phone (A2DP)
    ↓
BlueALSA (with health checks + recovery)
    ↓
bt2fm.sh (with auto-failsafe + bounds)
    ↓
PiFmRds (pre-validated binary)
    ↓
Radio (88-108 MHz)
    ↓
[Error Recovery]
```

### After Phase 2: Quality
```
[Selection UI]
  ↓ ↓ ↓
Device | Language | Quality
    ↓
[Validation + Selection]
    ↓
Phone (A2DP, multi-adapter)
    ↓
BlueALSA (health monitored)
    ↓
bt2fm.sh (with degradation)
    ↓
PiFmRds (pre-validated)
    ↓
[High-Quality TTS]
    ↓
Radio (88-108 MHz, FCC-compliant)
    ↓
[Comprehensive Testing]
```

### After Phase 3: Documented
```
All of above + 
    ├─ Service dependency graph
    ├─ Troubleshooting flowchart
    ├─ Performance metrics
    ├─ Regulatory compliance matrix
    └─ Developer onboarding guide
```

---

## 🔄 Dependency Chain

```
[Phase 1: Robustness]
    ├─ Task #1: PiFmRds validation
    ├─ Task #2: GPIO4 detection
    ├─ Task #3: RDS FIFO recovery ──┐
    ├─ Task #4: Audio failsafe      ├─→ [Phase 2 can start]
    └─ Task #5: Freq bounds ────────┘
        ↓
[Phase 2: Quality]
    ├─ Task #6: TTS sox upgrade
    ├─ Task #7: TTS language ───┐
    ├─ Task #8: BT device sel   ├─→ [Phase 3 can start]
    ├─ Task #9: Freq validation ┤
    └─ Task #22: Test suite ────┘
        ↓
[Phase 3: Documentation]
    ├─ Task #10: AGENTS TTS guide
    ├─ Task #11: AGENTS compliance
    ├─ Task #12: Troubleshooting ──→ [Release v2.0]
    └─ ... other docs
```

**Note:** Some tasks can run in parallel (documentation tasks don't block code tasks)

---

## 🚀 Success Criteria by Phase

### Phase 1 ✓ Success
- [ ] Zero test failures
- [ ] All 5 critical tasks merged
- [ ] Git history shows incremental commits
- [ ] New test cases added
- [ ] Validation happens before startup

### Phase 2 ✓ Success
- [ ] TTS quality rated >8/10 in testing
- [ ] Multi-device support verified
- [ ] 100+ integration tests passing
- [ ] All 8 high-priority tasks merged
- [ ] Feature parity with Phase 1 + improvements

### Phase 3 ✓ Success
- [ ] Documentation rated >9/10 clarity
- [ ] Troubleshooting guide solves >90% of issues
- [ ] New developer can onboard in <2 hours
- [ ] All 7 medium tasks merged
- [ ] Zero documentation TODOs remain

### Phase 4 ✓ Success (Optional)
- [ ] Memory footprint <50MB
- [ ] Auto-recovery works for all services
- [ ] Status command provides actionable insights
- [ ] Release v2.0 final

---

## 📢 Communication & Release Plan

### Phase 1 Release (v1.5-robustness)
- Target: Early March 2024
- Changes: Internal reliability improvements
- Breaking: None
- Migration: No action required

### Phase 2 Release (v1.7-quality)
- Target: Mid March 2024
- Changes: Audio quality, new features
- Breaking: None (backward compatible)
- New Features: TTS language, device selection
- Migration: Optional (old configs still work)

### Phase 3 Release (v2.0-documented)
- Target: End March 2024
- Changes: Documentation complete
- Breaking: None
- New: Troubleshooting guides, compliance info
- Migration: No action required

### Phase 4 Release (v2.1-optimized)
- Target: Q2 2024 (stretch goal)
- Changes: Performance & polish
- Breaking: None
- Deprecated: None
- Migration: No action required

---

## 🤝 Contribution Guidelines

During implementation:
1. Work on one phase at a time
2. Create feature branches: `feat/robustness-task-1`, etc.
3. Add tests for each task
4. Update documentation inline
5. Commit atomically (one task = one or more commits)
6. Link PRs to tasks in TODO.md

Example:
```bash
git checkout -b feat/robustness-pifmrds-validation
# Implement Task #1
# Write tests
# Update AGENTS.md
git commit -m "Add PiFmRds binary validation after build"
git push origin feat/robustness-pifmrds-validation
# Create PR
```

---

## 📈 Metrics & Monitoring

Track these over time:
- **Code Coverage:** Currently ~60%, target >85% by Phase 3
- **Documentation:** Currently ~70%, target >95% by Phase 3
- **Test Pass Rate:** Currently ~100%, maintain
- **Issue Resolution Time:** Monitor PR turnaround
- **Community Feedback:** GitHub issues/discussions

---

## 🔮 Future Vision (Post-2024)

Not in current roadmap but worth considering:
- AirPlay (RAOP) support alongside A2DP
- Web UI for configuration
- Mobile app for frequency control
- Playlist support
- Recording capability (second instance)
- Docker containerization
- Kubernetes deployment guide

---

## 📞 Questions?

See [TODO.md](./TODO.md) for detailed task breakdown  
See [AGENTS.md](./AGENTS.md) for contribution guidelines  
See [README.md](./README.md) for usage & troubleshooting
