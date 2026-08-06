import XCTest
@testable import GloriousSync
import GMMKProtocol
import GloriousMouseProtocol

/// The whole translation table: every family against both devices, plus the
/// boundaries of each normalised scale.
///
/// This layer is pure, so these tests are the only thing standing between a
/// mapping mistake and two devices quietly disagreeing about what the desk is
/// supposed to look like.
final class GloriousSyncTests: XCTestCase {

    private let teal = DeskColor(hex: "00ccaa")!

    private func look(_ family: DeskEffectFamily,
                      brightness: Double = 1.0,
                      speed: Double = 0.5) -> DeskLook {
        DeskLook(family: family, color: teal, brightness: brightness, speed: speed)
    }

    // MARK: - Families → keyboard

    func testEveryFamilyMapsToAKeyboardMode() {
        let expected: [DeskEffectFamily: LightingMode] = [
            .solid: .fixed,
            .breathing: .breathing,
            .wave: .horizontalWave,
            .rainbowCycle: .horizontalWave,
        ]
        for family in DeskEffectFamily.allCases {
            XCTAssertEqual(GloriousSync.keyboardMode(for: family), expected[family],
                           family.rawValue)
        }
    }

    /// Wave and rainbow cycle are the *same mode* with the flag off and on —
    /// which is exactly how the hardware works.
    func testOnlyRainbowCycleSetsTheRainbowFlag() {
        for family in DeskEffectFamily.allCases {
            let plan = GloriousSync.keyboardPlan(for: look(family))
            XCTAssertEqual(plan.rainbow, family == .rainbowCycle, family.rawValue)
        }
        let wave = GloriousSync.keyboardPlan(for: look(.wave))
        let cycle = GloriousSync.keyboardPlan(for: look(.rainbowCycle))
        XCTAssertEqual(wave.mode, cycle.mode)
        XCTAssertNotEqual(wave.rainbow, cycle.rainbow)
    }

    func testKeyboardPlanCarriesTheLooksColor() {
        for family in DeskEffectFamily.allCases {
            let plan = GloriousSync.keyboardPlan(for: look(family))
            XCTAssertEqual(plan.color, RGB(red: 0x00, green: 0xCC, blue: 0xAA), family.rawValue)
        }
    }

    // MARK: - Families → mouse

    func testEveryFamilyMapsToAMouseEffect() {
        let expected: [DeskEffectFamily: MouseRGBEffect] = [
            .solid: .single,
            .breathing: .breathing1,
            .wave: .rainbow,
            .rainbowCycle: .rainbow,
        ]
        for family in DeskEffectFamily.allCases {
            XCTAssertEqual(GloriousSync.mouseEffect(for: family), expected[family],
                           family.rawValue)
        }
    }

    /// The two travelling families share an effect and are told apart by
    /// direction, so the directions must actually differ.
    func testTravellingFamiliesDifferByDirection() {
        XCTAssertEqual(GloriousSync.mouseRainbowDirection(for: .wave), .up)
        XCTAssertEqual(GloriousSync.mouseRainbowDirection(for: .rainbowCycle), .down)
        XCTAssertNil(GloriousSync.mouseRainbowDirection(for: .solid))
        XCTAssertNil(GloriousSync.mouseRainbowDirection(for: .breathing))

        let wave = GloriousSync.mousePlan(for: look(.wave))
        let cycle = GloriousSync.mousePlan(for: look(.rainbowCycle))
        XCTAssertEqual(wave.effect, cycle.effect)
        XCTAssertNotEqual(wave.rainbowDirection, cycle.rainbowDirection)
    }

    /// A colour is only carried where the effect has somewhere to put it — the
    /// rainbow effect has no colour array at all.
    func testMousePlanOnlyCarriesAColourWhereTheEffectHasOne() {
        XCTAssertEqual(GloriousSync.mousePlan(for: look(.solid)).color,
                       MouseRGB(red: 0x00, green: 0xCC, blue: 0xAA))
        XCTAssertEqual(GloriousSync.mousePlan(for: look(.breathing)).color,
                       MouseRGB(red: 0x00, green: 0xCC, blue: 0xAA))
        XCTAssertNil(GloriousSync.mousePlan(for: look(.wave)).color)
        XCTAssertNil(GloriousSync.mousePlan(for: look(.rainbowCycle)).color)

        for family in DeskEffectFamily.allCases {
            let plan = GloriousSync.mousePlan(for: look(family))
            XCTAssertEqual(plan.color != nil, plan.effect.colorArray != nil, family.rawValue)
        }
    }

    /// ``DeskEffectFamily/usesColor`` means "visible on at least one device",
    /// which is exactly the keyboard's answer — the keyboard shows the colour
    /// for every family except the rainbow cycle.
    func testUsesColorMatchesTheKeyboard() {
        for family in DeskEffectFamily.allCases {
            let plan = GloriousSync.keyboardPlan(for: look(family))
            XCTAssertEqual(family.usesColor, !plan.rainbow, family.rawValue)
        }
    }

    /// **Wave is coloured on the keyboard and rainbow on the mouse**, because
    /// the mouse renders travelling effects as a hue sweep with no colour
    /// parameter. Anything that assumes the two devices agree about the colour
    /// is wrong for this one family, so it is pinned here.
    func testWaveIsColouredOnTheKeyboardButNotOnTheMouse() {
        let wave = look(.wave)
        XCTAssertFalse(GloriousSync.keyboardPlan(for: wave).rainbow)
        XCTAssertNil(GloriousSync.mousePlan(for: wave).color)

        // Solid and breathing do agree.
        for family: DeskEffectFamily in [.solid, .breathing] {
            XCTAssertFalse(GloriousSync.keyboardPlan(for: look(family)).rainbow)
            XCTAssertNotNil(GloriousSync.mousePlan(for: look(family)).color)
        }
        // The rainbow cycle agrees the other way: no colour anywhere.
        XCTAssertTrue(GloriousSync.keyboardPlan(for: look(.rainbowCycle)).rainbow)
        XCTAssertNil(GloriousSync.mousePlan(for: look(.rainbowCycle)).color)
    }

    // MARK: - Brightness

    /// 0 is off on the keyboard; every non-zero value lights something.
    func testKeyboardBrightnessBoundaries() {
        XCTAssertEqual(GloriousSync.keyboardBrightnessLevel(0), 0)
        XCTAssertEqual(GloriousSync.keyboardBrightnessLevel(0.01), 1)
        XCTAssertEqual(GloriousSync.keyboardBrightnessLevel(0.25), 1)
        XCTAssertEqual(GloriousSync.keyboardBrightnessLevel(0.5), 2)
        XCTAssertEqual(GloriousSync.keyboardBrightnessLevel(0.8), 3)
        XCTAssertEqual(GloriousSync.keyboardBrightnessLevel(1), 4)
        // Out of range clamps rather than wrapping.
        XCTAssertEqual(GloriousSync.keyboardBrightnessLevel(-5), 0)
        XCTAssertEqual(GloriousSync.keyboardBrightnessLevel(9), 4)
    }

    /// **The mouse never goes fully dark from a look**: its 0 means LEDs off,
    /// which would read as a broken mouse rather than a dim one.
    func testMouseBrightnessNeverReachesZero() {
        XCTAssertEqual(GloriousSync.mouseBrightness(0), 1)
        XCTAssertEqual(GloriousSync.mouseBrightness(1.0 / 3.0), 2)
        XCTAssertEqual(GloriousSync.mouseBrightness(2.0 / 3.0), 3)
        XCTAssertEqual(GloriousSync.mouseBrightness(1), 4)
        XCTAssertEqual(GloriousSync.mouseBrightness(-5), 1)
        XCTAssertEqual(GloriousSync.mouseBrightness(9), 4)

        for step in 0...20 {
            let level = GloriousSync.mouseBrightness(Double(step) / 20)
            XCTAssertTrue((1...MouseModeParameter.maxBrightness).contains(level),
                          "brightness \(step)/20 → \(level)")
        }
    }

    // MARK: - Speed

    /// The keyboard's field is a **delay**, so the mapping is inverted:
    /// fastest is 0.
    func testKeyboardSpeedIsInverted() {
        XCTAssertEqual(GloriousSync.keyboardDelay(0), 3)     // slowest
        XCTAssertEqual(GloriousSync.keyboardDelay(1.0 / 3.0), 2)
        XCTAssertEqual(GloriousSync.keyboardDelay(2.0 / 3.0), 1)
        XCTAssertEqual(GloriousSync.keyboardDelay(1), 0)     // fastest
        XCTAssertEqual(GloriousSync.keyboardDelay(-5), 3)
        XCTAssertEqual(GloriousSync.keyboardDelay(9), 0)
    }

    /// The mouse's field is a speed, so it runs the other way — and its 0
    /// ("static") is never used, or an animated look would come out frozen.
    func testMouseSpeedIsNotInvertedAndNeverStatic() {
        XCTAssertEqual(GloriousSync.mouseSpeed(0), 1)
        XCTAssertEqual(GloriousSync.mouseSpeed(0.5), 2)
        XCTAssertEqual(GloriousSync.mouseSpeed(1), 3)
        XCTAssertEqual(GloriousSync.mouseSpeed(-5), 1)
        XCTAssertEqual(GloriousSync.mouseSpeed(9), 3)

        for step in 0...20 {
            let speed = GloriousSync.mouseSpeed(Double(step) / 20)
            XCTAssertTrue((1...MouseModeParameter.maxSpeed).contains(speed),
                          "speed \(step)/20 → \(speed)")
        }
    }

    /// The two devices move in opposite directions for the same look, which is
    /// the single most confusable thing in this file.
    func testTheDevicesSpeedFieldsRunOppositeWays() {
        let fast = look(.wave, speed: 1)
        let slow = look(.wave, speed: 0)
        XCTAssertLessThan(GloriousSync.keyboardPlan(for: fast).delay,
                          GloriousSync.keyboardPlan(for: slow).delay)
        XCTAssertGreaterThan(GloriousSync.mousePlan(for: fast).parameter.speed,
                             GloriousSync.mousePlan(for: slow).parameter.speed)
    }

    // MARK: - Whole plans

    func testASolidLookInFull() {
        let plan = GloriousSync.keyboardPlan(
            for: DeskLook(family: .solid, color: DeskColor(hex: "66ffaa")!,
                          brightness: 1, speed: 0.5))
        XCTAssertEqual(plan, GloriousSync.KeyboardPlan(
            mode: .fixed, rainbow: false, brightnessLevel: 4, delay: 2,
            color: RGB(red: 0x66, green: 0xFF, blue: 0xAA)))

        let mouse = GloriousSync.mousePlan(
            for: DeskLook(family: .solid, color: DeskColor(hex: "66ffaa")!,
                          brightness: 1, speed: 0.5))
        XCTAssertEqual(mouse, GloriousSync.MousePlan(
            effect: .single,
            color: MouseRGB(red: 0x66, green: 0xFF, blue: 0xAA),
            parameter: MouseModeParameter(speed: 2, brightness: 4),
            rainbowDirection: nil))
    }

    func testARainbowLookIgnoresTheColourOnBothDevices() {
        let deskLook = DeskLook(family: .rainbowCycle, color: teal,
                                brightness: 0.5, speed: 0)
        let keyboard = GloriousSync.keyboardPlan(for: deskLook)
        XCTAssertTrue(keyboard.rainbow)
        XCTAssertEqual(keyboard.brightnessLevel, 2)
        XCTAssertEqual(keyboard.delay, 3)

        let mouse = GloriousSync.mousePlan(for: deskLook)
        XCTAssertEqual(mouse.effect, .rainbow)
        XCTAssertNil(mouse.color)
        XCTAssertEqual(mouse.parameter, MouseModeParameter(speed: 1, brightness: 3))
        XCTAssertEqual(mouse.rainbowDirection, .down)
    }

    /// Every family produces a plan for both devices — no family is a dead end.
    func testEveryFamilyProducesBothPlans() {
        for family in DeskEffectFamily.allCases {
            for brightness in [0.0, 0.5, 1.0] {
                for speed in [0.0, 0.5, 1.0] {
                    let deskLook = look(family, brightness: brightness, speed: speed)
                    let keyboard = GloriousSync.keyboardPlan(for: deskLook)
                    let mouse = GloriousSync.mousePlan(for: deskLook)
                    XCTAssertTrue((0...Brightness.max).contains(keyboard.brightnessLevel))
                    XCTAssertTrue((0...Delay.max).contains(keyboard.delay))
                    XCTAssertTrue((1...MouseModeParameter.maxBrightness)
                        .contains(mouse.parameter.brightness))
                    XCTAssertTrue((1...MouseModeParameter.maxSpeed)
                        .contains(mouse.parameter.speed))
                }
            }
        }
    }

    // MARK: - Reverse mapping

    func testKeyboardModesMapBackToFamilies() {
        XCTAssertEqual(GloriousSync.family(forKeyboardMode: .fixed, rainbow: false), .solid)
        XCTAssertEqual(GloriousSync.family(forKeyboardMode: .breathing, rainbow: false),
                       .breathing)
        XCTAssertEqual(GloriousSync.family(forKeyboardMode: .horizontalWave, rainbow: false),
                       .wave)
        XCTAssertEqual(GloriousSync.family(forKeyboardMode: .breathingCycle, rainbow: false),
                       .rainbowCycle)
    }

    /// The rainbow flag overrides the mode: whatever is running, it is a hue
    /// cycle once the flag is on.
    func testTheRainbowFlagWinsOverTheMode() {
        for mode in LightingMode.allCases {
            XCTAssertEqual(GloriousSync.family(forKeyboardMode: mode, rainbow: true),
                           .rainbowCycle, mode.displayName)
        }
    }

    /// Most keyboard modes have no counterpart, and saying so is the point —
    /// approximating would move the other device for no reason.
    func testUnmappableKeyboardModesReturnNil() {
        for mode: LightingMode in [.hurricane, .reactiveSingle, .waterfall, .swirl,
                                   .verticalWave, .sine, .vortex, .rain, .diagonalWave,
                                   .reactiveColor, .ripple, .off, .custom] {
            XCTAssertNil(GloriousSync.family(forKeyboardMode: mode, rainbow: false),
                         mode.displayName)
        }
    }

    func testMouseEffectsMapBackToFamilies() {
        XCTAssertEqual(GloriousSync.family(forMouseEffect: .single), .solid)
        XCTAssertEqual(GloriousSync.family(forMouseEffect: .breathing1), .breathing)
        XCTAssertEqual(GloriousSync.family(forMouseEffect: .wave), .wave)
        XCTAssertEqual(GloriousSync.family(forMouseEffect: .rainbow), .rainbowCycle)
        XCTAssertEqual(GloriousSync.family(forMouseEffect: .spectrumBreathing), .rainbowCycle)
    }

    func testUnmappableMouseEffectsReturnNil() {
        for effect: MouseRGBEffect in [.off, .breathing7, .tail, .constant, .rave, .random] {
            XCTAssertNil(GloriousSync.family(forMouseEffect: effect), effect.displayName)
        }
    }

    /// Forward then back is the identity on the families that survive the round
    /// trip. Wave is the exception by construction: it shares the mouse's
    /// rainbow effect with the cycle family, so the mouse cannot tell them
    /// apart on the way back.
    func testFamilyRoundTripsThroughTheKeyboard() {
        for family in DeskEffectFamily.allCases {
            let plan = GloriousSync.keyboardPlan(for: look(family))
            XCTAssertEqual(GloriousSync.family(forKeyboardMode: plan.mode,
                                               rainbow: plan.rainbow),
                           family, family.rawValue)
        }
    }

    func testBrightnessRoundTrips() {
        for level in UInt8(0)...4 {
            XCTAssertEqual(
                GloriousSync.keyboardBrightnessLevel(
                    GloriousSync.brightness01(fromKeyboardLevel: level)),
                level, "keyboard level \(level)")
        }
        for brightness in UInt8(1)...4 {
            XCTAssertEqual(
                GloriousSync.mouseBrightness(
                    GloriousSync.brightness01(fromMouseBrightness: brightness)),
                brightness, "mouse brightness \(brightness)")
        }
        // The mouse's "LEDs off" has no look equivalent, so it reads as darkest.
        XCTAssertEqual(GloriousSync.brightness01(fromMouseBrightness: 0), 0)
    }

    func testSpeedRoundTrips() {
        for delay in UInt8(0)...3 {
            XCTAssertEqual(
                GloriousSync.keyboardDelay(GloriousSync.speed01(fromKeyboardDelay: delay)),
                delay, "keyboard delay \(delay)")
        }
        for speed in UInt8(1)...3 {
            XCTAssertEqual(
                GloriousSync.mouseSpeed(GloriousSync.speed01(fromMouseSpeed: speed)),
                speed, "mouse speed \(speed)")
        }
        XCTAssertEqual(GloriousSync.speed01(fromMouseSpeed: 0), 0)
    }

    /// A brightness carried across to the other device and back cannot be exact
    /// — the keyboard has five levels including off and the mouse has four that
    /// a look can name, so the two grids do not line up — but it must stay
    /// within one level rather than walking.
    ///
    /// This only matters if a value makes the round trip at all. The app applies
    /// a change to the *other* device and keeps the look itself as the canonical
    /// value, so nothing ping-pongs; the bound is here to keep it that way.
    func testBrightnessStaysWithinOneLevelAcrossADeviceHop() {
        for level in UInt8(0)...4 {
            let asLook = GloriousSync.brightness01(fromKeyboardLevel: level)
            let onMouse = GloriousSync.mouseBrightness(asLook)
            let backToLook = GloriousSync.brightness01(fromMouseBrightness: onMouse)
            let backOnKeyboard = GloriousSync.keyboardBrightnessLevel(backToLook)
            XCTAssertLessThanOrEqual(abs(Int(backOnKeyboard) - Int(level)), 1,
                                     "keyboard level \(level) came back as \(backOnKeyboard)")
        }
    }

    /// Brighter in always means brighter out, on both devices — the property
    /// that actually matters when a slider is being dragged.
    func testBrightnessIsMonotonicOnBothDevices() {
        var lastKeyboard = GloriousSync.keyboardBrightnessLevel(0)
        var lastMouse = GloriousSync.mouseBrightness(0)
        for step in 1...20 {
            let value = Double(step) / 20
            let keyboard = GloriousSync.keyboardBrightnessLevel(value)
            let mouse = GloriousSync.mouseBrightness(value)
            XCTAssertGreaterThanOrEqual(keyboard, lastKeyboard, "keyboard at \(value)")
            XCTAssertGreaterThanOrEqual(mouse, lastMouse, "mouse at \(value)")
            lastKeyboard = keyboard
            lastMouse = mouse
        }
        XCTAssertEqual(lastKeyboard, Brightness.max)
        XCTAssertEqual(lastMouse, MouseModeParameter.maxBrightness)
    }

    /// The same, for speed — remembering that the keyboard's field runs
    /// backwards, so "faster" means a *smaller* delay.
    func testSpeedIsMonotonicOnBothDevices() {
        var lastDelay = GloriousSync.keyboardDelay(0)
        var lastMouse = GloriousSync.mouseSpeed(0)
        for step in 1...20 {
            let value = Double(step) / 20
            let delay = GloriousSync.keyboardDelay(value)
            let mouse = GloriousSync.mouseSpeed(value)
            XCTAssertLessThanOrEqual(delay, lastDelay, "keyboard at \(value)")
            XCTAssertGreaterThanOrEqual(mouse, lastMouse, "mouse at \(value)")
            lastDelay = delay
            lastMouse = mouse
        }
        XCTAssertEqual(lastDelay, 0)
        XCTAssertEqual(lastMouse, MouseModeParameter.maxSpeed)
    }

    // MARK: - Themes

    /// Every theme, both devices, byte for byte. A theme is a fixed promise
    /// about what the desk will look like, so the expectations are spelled out
    /// rather than recomputed from the same table that produces them.
    func testEveryThemeTranslatesToBothDevices() {
        // name → (keyboard mode, rainbow, brightness level, delay,
        //         mouse effect, mouse colour or nil, mouse speed, mouse brightness)
        let expected: [String: (LightingMode, Bool, UInt8, UInt8,
                                MouseRGBEffect, String?, UInt8, UInt8)] = [
            // Easy on the switches
            "Mint Uniform":  (.fixed, false, 4, 2, .single, "66ffaa", 2, 4),
            "Seafoam Wave":  (.horizontalWave, false, 4, 2, .rainbow, nil, 2, 4),
            "Ocean":         (.horizontalWave, true, 4, 2, .rainbow, nil, 2, 4),
            "Ember":         (.breathing, false, 3, 2, .breathing1, "ff5500", 2, 3),
            "Ice":           (.fixed, false, 4, 2, .single, "99e6ff", 2, 4),
            "Midnight":      (.fixed, false, 1, 2, .single, "3344ff", 2, 2),
            // Loud
            "Magenta Blast": (.fixed, false, 4, 2, .single, "ff00ff", 2, 4),
            "Ultraviolet":   (.breathing, false, 4, 2, .breathing1, "8800ff", 2, 4),
            "Acid":          (.horizontalWave, false, 4, 2, .rainbow, nil, 2, 4),
            "Electric":      (.horizontalWave, false, 4, 0, .rainbow, nil, 3, 4),
            "Toxic":         (.fixed, false, 4, 2, .single, "39ff14", 2, 4),
            "Synthwave":     (.horizontalWave, true, 4, 0, .rainbow, nil, 3, 4),
            "Crimson":       (.breathing, false, 4, 2, .breathing1, "ff0022", 2, 4),
            "Sunset":        (.fixed, false, 4, 2, .single, "ff4400", 2, 4),
        ]
        XCTAssertEqual(Set(expected.keys), Set(DeskTheme.all.map(\.name)),
                       "a theme was added or renamed without updating this table")

        for entry in DeskTheme.all {
            guard let want = expected[entry.name] else { continue }
            let keyboard = GloriousSync.keyboardPlan(for: entry.look)
            XCTAssertEqual(keyboard.mode, want.0, "\(entry.name) keyboard mode")
            XCTAssertEqual(keyboard.rainbow, want.1, "\(entry.name) rainbow flag")
            XCTAssertEqual(keyboard.brightnessLevel, want.2, "\(entry.name) keyboard brightness")
            XCTAssertEqual(keyboard.delay, want.3, "\(entry.name) keyboard delay")
            XCTAssertEqual(keyboard.color, entry.look.color.keyboardColor,
                           "\(entry.name) keyboard colour")

            let mouse = GloriousSync.mousePlan(for: entry.look)
            XCTAssertEqual(mouse.effect, want.4, "\(entry.name) mouse effect")
            XCTAssertEqual(mouse.color, want.5.map { MouseRGB(hex: $0)! },
                           "\(entry.name) mouse colour")
            XCTAssertEqual(mouse.parameter.speed, want.6, "\(entry.name) mouse speed")
            XCTAssertEqual(mouse.parameter.brightness, want.7, "\(entry.name) mouse brightness")
        }
    }

    /// The loud group is loud: every one of its themes is at full brightness on
    /// both devices, which is the whole point of the group.
    func testLoudThemesAreFullBrightness() {
        for entry in DeskTheme.loud.entries {
            XCTAssertEqual(GloriousSync.keyboardPlan(for: entry.look).brightnessLevel,
                           Brightness.max, entry.name)
            XCTAssertEqual(GloriousSync.mousePlan(for: entry.look).parameter.brightness,
                           MouseModeParameter.maxBrightness, entry.name)
        }
    }

    /// **Red-heavy themes are passed through unchanged.** Crimson and Sunset
    /// will show a mixed-switch board's mix, and that is the user's choice —
    /// nothing here desaturates or shifts them on the way to either device.
    func testRedHeavyThemesAreNotSoftened() {
        for name in ["Crimson", "Sunset"] {
            let entry = DeskTheme.all.first { $0.name == name }!
            XCTAssertGreaterThan(SwitchCompensation.redFraction(entry.look.color.keyboardColor),
                                 SwitchCompensation.redHeavyThreshold,
                                 "\(name) should be red-heavy — it is meant to be")
            // Byte-for-byte the colour that was named, on both devices.
            XCTAssertEqual(GloriousSync.keyboardPlan(for: entry.look).color,
                           entry.look.color.keyboardColor, name)
            XCTAssertEqual(GloriousSync.mousePlan(for: entry.look).color,
                           entry.look.color.mouseColor, name)
        }
    }

    /// The switch-friendly group is green and blue with **one** documented
    /// exception: Ember, a warm look kept there because it is calm rather than
    /// loud. Pinning the count to one is what makes this a real check — add
    /// another red theme to that group and this fails.
    func testSwitchFriendlyGroupHasExactlyOneRedHeavyException() {
        let redHeavy = DeskTheme.switchFriendly.entries.filter {
            SwitchCompensation.isRedHeavy($0.look.color.keyboardColor)
        }
        XCTAssertEqual(redHeavy.map(\.name), ["Ember"])
    }

    /// The loud group is where red-heavy looks are expected rather than
    /// excepted, so it has to actually contain some.
    func testLoudGroupContainsRedHeavyThemes() {
        let redHeavy = DeskTheme.loud.entries.filter {
            SwitchCompensation.isRedHeavy($0.look.color.keyboardColor)
        }
        XCTAssertTrue(redHeavy.map(\.name).contains("Crimson"))
        XCTAssertTrue(redHeavy.map(\.name).contains("Sunset"))
    }

    func testGroupsCoverEveryThemeExactlyOnce() {
        XCTAssertEqual(DeskTheme.groups.count, 2)
        XCTAssertEqual(DeskTheme.all.count,
                       DeskTheme.groups.reduce(0) { $0 + $1.entries.count })
        let names = DeskTheme.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "a theme name is duplicated across groups")
        for group in DeskTheme.groups {
            XCTAssertFalse(group.name.isEmpty)
            XCTAssertFalse(group.entries.isEmpty)
        }
    }

    func testEveryThemeIsUsable() {
        XCTAssertEqual(DeskTheme.all.count, 14)
        XCTAssertEqual(DeskTheme.switchFriendly.entries.count, 6)
        XCTAssertEqual(DeskTheme.loud.entries.count, 8)
        let names = DeskTheme.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains(""))
        for entry in DeskTheme.all {
            XCTAssertTrue((0...1).contains(entry.look.brightness), entry.name)
            XCTAssertTrue((0...1).contains(entry.look.speed), entry.name)
            // Both plans exist for every theme, which is what "applies to
            // whichever devices are present" depends on.
            _ = GloriousSync.keyboardPlan(for: entry.look)
            _ = GloriousSync.mousePlan(for: entry.look)
        }
    }

    func testThemesCoverMoreThanOneFamily() {
        let families = Set(DeskTheme.all.map(\.look.family))
        XCTAssertTrue(families.contains(.solid))
        XCTAssertTrue(families.contains(.wave))
        XCTAssertTrue(families.contains(.rainbowCycle))
        XCTAssertTrue(families.contains(.breathing))
    }

    func testMidnightIsDimAndMintIsFull() {
        let midnight = DeskTheme.all.first { $0.name == "Midnight" }!
        let mint = DeskTheme.all.first { $0.name == "Mint Uniform" }!
        XCTAssertLessThan(GloriousSync.keyboardPlan(for: midnight.look).brightnessLevel,
                          GloriousSync.keyboardPlan(for: mint.look).brightnessLevel)
        XCTAssertLessThan(GloriousSync.mousePlan(for: midnight.look).parameter.brightness,
                          GloriousSync.mousePlan(for: mint.look).parameter.brightness)
    }

    // MARK: - Colour conversion

    func testColorConvertsToBothDeviceTypes() {
        let color = DeskColor(hex: "ff8800")!
        XCTAssertEqual(color.keyboardColor, RGB(red: 0xFF, green: 0x88, blue: 0x00))
        XCTAssertEqual(color.mouseColor, MouseRGB(red: 0xFF, green: 0x88, blue: 0x00))
        // The mouse stores R,B,G on the wire; the conversion must not pre-swap.
        XCTAssertEqual(color.mouseColor.rbgBytes, [0xFF, 0x00, 0x88])
        XCTAssertEqual(color.hexString, "ff8800")
    }

    func testColorRoundTripsThroughBothDeviceTypes() {
        let color = DeskColor(hex: "123456")!
        XCTAssertEqual(DeskColor(color.keyboardColor), color)
        XCTAssertEqual(DeskColor(color.mouseColor), color)
    }

    func testMalformedHexIsRejected() {
        XCTAssertNil(DeskColor(hex: "fff"))
        XCTAssertNil(DeskColor(hex: "gggggg"))
    }
}
