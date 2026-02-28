# Waveform Viewing Guide for Switch1T

## Document Information
- **Date**: 2026-02-06
- **Tool**: GTKWave (recommended), Simvision, Verdi
- **Format**: VCD (Value Change Dump)

---

## 1. Generating Waveforms

### 1.1 Enable Waveform Dump in Testbench

Add the following to your testbench:

```systemverilog
initial begin
    $dumpfile("tb_mac_table.vcd");
    $dumpvars(0, tb_mac_table);
end
```

**Parameters:**
- `$dumpfile("filename.vcd")` - Specifies output file
- `$dumpvars(level, scope)` - Controls what to dump
  - `level = 0` - Dump all signals in hierarchy
  - `level = 1` - Dump only signals at current level
  - `scope` - Module instance to dump

### 1.2 Compile with Trace Enabled

```bash
verilator --binary --trace \
    --top-module tb_mac_table \
    -I../rtl \
    ../rtl/switch_pkg.sv \
    ../rtl/mac_table.sv \
    ../tb/tb_mac_table.sv
```

**Important:** The `--trace` flag must be present!

### 1.3 Run Simulation

```bash
cd sim
./obj_dir/Vtb_mac_table
```

This generates `tb_mac_table.vcd` in the current directory.

---

## 2. Installing GTKWave

### Ubuntu/Debian
```bash
sudo apt-get install gtkwave
```

### macOS
```bash
brew install gtkwave
```

### Windows
Download from: https://sourceforge.net/projects/gtkwave/

---

## 3. Opening Waveforms in GTKWave

### 3.1 Basic Launch
```bash
cd sim
gtkwave tb_mac_table.vcd &
```

### 3.2 GTKWave Interface

```
┌─────────────────────────────────────────────────────────────┐
│  File  Edit  Search  Time  Markers  View  Help              │
├────────────┬────────────────────────────────────────────────┤
│ SST        │  Signals                                        │
│ (Hierarchy)│  (Waveform Display Area)                        │
│            │                                                  │
│ tb_mac     │  clk          ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁       │
│  └─dut     │  rst_n     ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁     │
│    ├─mac   │  learn_req ▁▁▁▁▁██▁▁▁▁▁██▁▁▁▁▁██▁▁▁▁▁          │
│    └─...   │  learn_mac 00aabbccddee 001122334455           │
│            │                                                  │
├────────────┴────────────────────────────────────────────────┤
│ Time: 0ns                     Zoom: 1ns/div                  │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 Key GTKWave Shortcuts

| Key | Action |
|-----|--------|
| **Ctrl + O** | Open VCD file |
| **Ctrl + W** | Close VCD file |
| **Ctrl + F** | Search signals |
| **Alt + W** | Zoom fit (show entire simulation) |
| **Ctrl + +** | Zoom in |
| **Ctrl + -** | Zoom out |
| **Space** | Cycle signal format (Binary/Hex/Decimal) |
| **Shift + Click** | Add marker |
| **Right Click** | Signal format menu |

---

## 4. MAC Table Module Waveform Analysis

### 4.1 Key Signals to Monitor

#### Clock and Reset
- `tb_mac_table.clk` - System clock
- `tb_mac_table.rst_n` - Active-low reset

#### Learning Interface
- `tb_mac_table.learn_req` - Learn request pulse
- `tb_mac_table.learn_mac[47:0]` - MAC address to learn
- `tb_mac_table.learn_vid[11:0]` - VLAN ID
- `tb_mac_table.learn_port[5:0]` - Source port
- `tb_mac_table.learn_done` - Learning complete
- `tb_mac_table.learn_success` - Learning succeeded

#### Lookup Interface
- `tb_mac_table.lookup_req` - Lookup request pulse
- `tb_mac_table.lookup_mac[47:0]` - MAC to look up
- `tb_mac_table.lookup_vid[11:0]` - VLAN ID
- `tb_mac_table.lookup_valid` - Result valid
- `tb_mac_table.lookup_hit` - Lookup hit/miss
- `tb_mac_table.lookup_port[5:0]` - Destination port

#### Internal State Machine
- `tb_mac_table.dut.learn_state` - Learning FSM state
  - `0 = LEARN_IDLE`
  - `1 = LEARN_HASH`
  - `2 = LEARN_READ`
  - `3 = LEARN_CHECK`
  - `4 = LEARN_WRITE`
  - `5 = LEARN_DONE`

#### Pipeline Stages
- `tb_mac_table.dut.s1_valid` - Stage 1 valid
- `tb_mac_table.dut.s2_valid` - Stage 2 valid
- `tb_mac_table.dut.s3_valid` - Stage 3 valid
- `tb_mac_table.dut.s3_hit` - Stage 3 hit signal

#### Memory Array (careful - large!)
- `tb_mac_table.dut.mac_mem[set][way]` - MAC memory array

#### Statistics
- `tb_mac_table.dut.stat_lookup_cnt` - Lookup count
- `tb_mac_table.dut.stat_hit_cnt` - Hit count
- `tb_mac_table.dut.stat_miss_cnt` - Miss count
- `tb_mac_table.dut.stat_learn_cnt` - Learn count

### 4.2 Signal Groups in GTKWave

Create signal groups for better organization:

#### Group 1: Clocking
```
clk
rst_n
```

#### Group 2: Learn Interface
```
learn_req
learn_mac
learn_vid
learn_port
learn_done
learn_success
dut.learn_state
```

#### Group 3: Lookup Interface
```
lookup_req
lookup_mac
lookup_vid
lookup_valid
lookup_hit
lookup_port
```

#### Group 4: Pipeline
```
dut.s1_valid
dut.s1_hit
dut.s2_valid
dut.s2_hit
dut.s3_valid
dut.s3_hit
```

#### Group 5: Statistics
```
dut.stat_lookup_cnt
dut.stat_hit_cnt
dut.stat_miss_cnt
dut.stat_learn_cnt
dut.stat_entry_cnt
```

---

## 5. Common Waveform Analysis Patterns

### 5.1 Learning Sequence

**Expected Pattern:**
```
Time: 0ns
learn_req:     ▁▁▁██▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁
learn_mac:     XXXXXXX 00aabbccddee XXXX
learn_state:   IDLE HASH READ CHECK WRITE DONE IDLE
learn_done:    ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁██▁
learn_success: ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁██▁
```

**Timing:**
- `learn_req` asserted for 1 cycle
- State machine takes ~6-7 cycles
- `learn_done` pulses for 1 cycle

### 5.2 Lookup Sequence

**Expected Pattern:**
```
Time: 0ns
lookup_req:   ▁▁██▁▁▁▁▁▁▁▁▁▁▁▁
lookup_mac:   XX 00aabbccddee XXXX
s1_valid:     ▁▁▁██▁▁▁▁▁▁▁▁▁▁
s2_valid:     ▁▁▁▁██▁▁▁▁▁▁▁▁▁
s3_valid:     ▁▁▁▁▁██▁▁▁▁▁▁▁▁
lookup_valid: ▁▁▁▁▁██▁▁▁▁▁▁▁▁
lookup_hit:   ▁▁▁▁▁██▁▁▁▁▁▁▁▁
```

**Timing:**
- `lookup_req` asserted for 1 cycle
- Pipeline takes 3 cycles
- Result valid after 3 cycles

### 5.3 Aging Sequence

**Expected Pattern:**
```
age_tick:     ▁▁▁██▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁
age_scanning: ▁▁▁▁██████████████████████▁
age_scan_idx: XX 0000 0001 0002 ... 1FFF
age_scan_way: XX 00 01 10 11 00 01 10 11 ...
```

**Timing:**
- `age_tick` triggers scan
- Scans all 8K sets × 4 ways = 32K entries
- Takes ~32K cycles to complete

---

## 6. Debugging Common Issues

### 6.1 Learn Request Not Completing

**Symptoms:**
- `learn_req` asserted but `learn_done` never pulses

**Debug Steps:**
1. Check `learn_state` - stuck in which state?
2. Check `learn_set_idx` - valid index?
3. Check `learn_found_empty` or `learn_found_match` - neither true?
4. Check `mac_mem` array - is it full?

**Waveform Check:**
```
learn_req:     ▁▁██▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁
learn_state:   IDLE HASH READ CHECK STUCK!
learn_done:    ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁  (NEVER PULSES)
```

### 6.2 Lookup Not Hitting

**Symptoms:**
- Learned MAC but lookup returns miss

**Debug Steps:**
1. Verify `lookup_mac` matches `learn_mac`
2. Verify `lookup_vid` matches `learn_vid`
3. Check hash calculation: `dut.compute_hash`
4. Verify entry is in `mac_mem[hash_idx][way]`

**Waveform Check:**
```
learn_mac:    00aabbccddee
learn_vid:    0001
learn_set_idx: 1234

lookup_mac:   00aabbccddee
lookup_vid:   0001
s1_set_idx:   1234  (SHOULD MATCH!)
s3_hit:       0     (MISS - WHY?)
```

### 6.3 Pipeline Stall

**Symptoms:**
- Requests queuing up, no progress

**Debug Steps:**
1. Check `s1_valid`, `s2_valid`, `s3_valid` - all high?
2. Check for backpressure
3. Verify clock is toggling

**Waveform Check:**
```
clk:      ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁  (NOT TOGGLING?)
s1_valid: ██████████████████  (STUCK?)
s2_valid: ██████████████████
s3_valid: ██████████████████
```

---

## 7. Advanced GTKWave Features

### 7.1 Signal Highlighting

Right-click signal → **Highlight**
- Choose color for important signals
- Helps distinguish between signal groups

### 7.2 Markers

- Press **Shift + Click** in waveform area to add marker
- Use to mark important events:
  - Start of test case
  - Expected vs actual timing
  - Error conditions

### 7.3 Measurement

1. Add two markers (Marker A and B)
2. GTKWave shows time difference at bottom
3. Use to measure:
   - Latency (request to response)
   - Pulse width
   - Period

Example:
```
Marker A: 1000ns (learn_req asserted)
Marker B: 1070ns (learn_done asserted)
Delta: 70ns = 7 cycles @ 10ns period
```

### 7.4 Signal Formatting

Right-click signal → **Data Format**
- **Binary** - Show as 0s and 1s
- **Hex** - Show as hexadecimal
- **Decimal** - Show as decimal
- **ASCII** - Show as ASCII characters
- **Enum** - Show enum names (if available)

**Recommended Formats:**
- MAC addresses: Hex
- Counters: Decimal
- State machines: Enum or Decimal
- Control signals: Binary

### 7.5 Save/Load Sessions

**Save:**
1. File → **Write Save File**
2. Saves signal selection and layout
3. Filename: `tb_mac_table.gtkw`

**Load:**
```bash
gtkwave tb_mac_table.vcd tb_mac_table.gtkw
```

---

## 8. Example GTKWave Session

### Step-by-Step Tutorial

#### Step 1: Open Waveform
```bash
cd switch1t/sim
gtkwave tb_mac_table.vcd &
```

#### Step 2: Navigate Hierarchy
1. In left panel (SST), expand `tb_mac_table`
2. Expand `dut` to see MAC table internals
3. Double-click hierarchy to see signals

#### Step 3: Add Signals
1. Click `tb_mac_table` in hierarchy
2. In signals pane, select:
   - `clk`
   - `rst_n`
   - `learn_req`
   - `learn_mac`
   - `learn_done`
3. Drag signals to waveform pane **OR** press **Append**

#### Step 4: Format Signals
1. Right-click `learn_mac` → **Data Format** → **Hex**
2. Right-click `learn_req` → **Data Format** → **Binary**

#### Step 5: Zoom to Fit
1. Press **Alt + W** to fit entire simulation
2. Use scroll wheel to zoom
3. Click and drag to pan

#### Step 6: Find Events
1. Press **Ctrl + F** to open search
2. Search for `learn_req`
3. Click **Next** to jump to each edge

#### Step 7: Measure Timing
1. Shift + Click at `learn_req` rising edge (Marker A)
2. Shift + Click at `learn_done` rising edge (Marker B)
3. Check status bar for time delta

---

## 9. Troubleshooting

### 9.1 No VCD File Generated

**Problem:** `tb_mac_table.vcd` not found

**Solutions:**
1. Check testbench has `$dumpfile()` and `$dumpvars()`
2. Verify `--trace` flag in verilator command
3. Check simulation actually ran (not just compiled)
4. Look for VCD in working directory

### 9.2 VCD File Empty or Truncated

**Problem:** VCD opens but no signals or incomplete

**Solutions:**
1. Simulation crashed before `$finish`
2. File corruption - try regenerating
3. Disk full during simulation
4. Add `$dumpflush` in testbench for incremental dumps

### 9.3 GTKWave Slow with Large VCD

**Problem:** GTKWave sluggish with large files

**Solutions:**
1. Reduce dump scope: `$dumpvars(1, tb_mac_table)` (level 1 only)
2. Dump specific signals only
3. Reduce simulation time
4. Use FST format instead: `$dumpfile("tb.fst")` with `--trace-fst`

### 9.4 Signals Not Found

**Problem:** Can't find signals in hierarchy

**Solutions:**
1. Signal optimized away by Verilator
2. Signal name mangled - search for partial name
3. Check module hierarchy path
4. Add `/* verilator public */` to preserve signal

---

## 10. Alternative Waveform Viewers

### 10.1 Simvision (Cadence)

```bash
simvision tb_mac_table.vcd &
```

**Advantages:**
- Professional tool
- Better performance
- Advanced analysis features

**Disadvantages:**
- Requires Cadence license
- Not free

### 10.2 Verdi (Synopsys)

```bash
verdi -ssf tb_mac_table.fsdb &
```

**Note:** Requires FSDB format, not VCD

**Advantages:**
- Best-in-class waveform viewer
- Powerful debugging features
- Source code integration

**Disadvantages:**
- Expensive license
- Requires Synopsys tools

### 10.3 DVE (Synopsys)

```bash
dve -vpd tb_mac_table.vpd &
```

**Note:** VCS-specific format

---

## 11. Quick Reference Card

### Essential Commands
```bash
# Generate waveform
verilator --binary --trace --top-module tb_mac_table ...
./obj_dir/Vtb_mac_table

# View waveform
gtkwave tb_mac_table.vcd &

# With saved session
gtkwave tb_mac_table.vcd tb_mac_table.gtkw &
```

### Key Shortcuts
| Action | Shortcut |
|--------|----------|
| Zoom fit | Alt + W |
| Zoom in | Ctrl + + |
| Zoom out | Ctrl + - |
| Search | Ctrl + F |
| Add marker | Shift + Click |
| Toggle format | Space |

### Signal Format Specifiers
- `%b` - Binary
- `%h` - Hexadecimal
- `%d` - Decimal
- `%t` - Time
- `%s` - String

---

**End of Waveform Viewing Guide**
