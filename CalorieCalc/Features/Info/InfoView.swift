import SwiftUI

/// First-person walkthrough — the banking strategy, why I built this, the numbers that worked
/// for me, and how every tab fits together.
struct InfoView: View {

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Color.clear.frame(height: 0).id("top")
                    bigIdeaCard

                    section(
                        title: "Calories in vs calories out",
                        icon: "arrow.left.arrow.right",
                        body:
                        """
                        Your body burns calories all day just to keep you alive — breathing, circulating blood, regulating temperature, digesting. The U.S. Dietary Guidelines for Americans (2020–2025) put a typical adult's daily burn, *before* any workouts, at:

                        • **Women, ages 19–60, sedentary:** 1,600–2,000 kcal/day
                        • **Men, ages 19–60, sedentary:** 2,200–2,600 kcal/day

                        "Sedentary" here means normal daily moving around — not bedridden. Once you add an active lifestyle the numbers climb roughly 400–600 kcal/day. Workouts pile on more burn on top of *that*, plus the obvious heart, sleep, mood, and mobility upside that the scale can't measure.

                        Weight loss isn't a mystery: eat fewer calories than you burn and the difference comes off your body. That gap is your **net calorie balance** — what you ate minus what you burned. A net of 500 below your typical burn, sustained, is roughly a pound a week.

                        CalorieCalc tracks both sides — every food entry adds to consumed, every workout (manual or HealthKit) adds to burned — and lets you set a daily **net goal** below your typical burn. Pick a realistic target (most people start a few hundred below their sedentary number), and the app handles the bookkeeping.

                        The wrinkle: hitting an exact net *every* day is brutal. Real life has dinners out. So CalorieCalc averages the net across the week — eat under on disciplined days, bank the difference, spend it on a bonus day. As long as the **week** averages out to your net goal, you're on plan. That's the rest of this guide.
                        """
                    )

                    section(
                        title: "Why I built this",
                        icon: "sparkles",
                        body:
                        """
                        I'm Patrick. I built this for myself.

                        Every big weight-loss app tries to work for everyone — keto, low sugar, body building, macros, fasting windows. I didn't need a system for somebody else's goals. I just wanted to know two things every day: **how much can I eat** to stay in the weight-loss zone, and **how much workout do I owe** to keep that number livable.

                        And — honestly — I wanted to be able to treat myself once in a while. A real dinner, a real dessert, no guilt. The fix was averaging: eat under on the disciplined days, bank the difference, spend it on a bigger day. Knowing a Friday steak or a Saturday ice cream wasn't going to torpedo the week made the whole thing actually sustainable. That single thing — the occasional larger meal *without* it being a relapse — made the difference between this approach working and the previous twenty things I'd tried not.

                        Using this exact approach I lost more than 60 lbs in under 6 months. Twice.

                        The first time I hit my goal, I stopped tracking — and slowly gained it all back. The second time I learned what I'd missed: at goal weight you don't *quit*, you just adjust. If the trend line creeps up, nudge the net down by 50–100 and watch it for a couple of weeks. That's maintenance.

                        I made this so the math runs itself and the strategy is the same whether I'm losing or holding.
                        """
                    )

                    section(
                        title: "The plan, with real numbers",
                        icon: "number",
                        body:
                        """
                        Your numbers will be different, but the shape is the same. Here's what worked for me.

                        **Losing fast.** Daily-net goal of **1,150 kcal**, planned workout burn of **350 kcal**. That gives me a 1,500-kcal eating *average*. Instead I ate 1,300 most days and banked the rest. That earned me one bonus day a week around **2,700 kcal** — a real dinner out, no guilt — and I still dropped about **2.5 lbs/week**.

                        **Closing in on goal.** Raised the net to **1,450** (still 350 burn). Same banking pattern gave me **~2,550 kcal** on the last two days. Down about **1 lb/week** with a much friendlier rhythm.

                        **Maintaining.** Bumped the net to **1,700**. Bonus days come in around **2,675 kcal**. Same banking, different setpoint. When the trend drifts up I drop the net slightly and let it stabilize.

                        The Calc tab does this math live, all day, every day.
                        """
                    )

                    section(
                        title: "Reading the Calc tab",
                        icon: "flame",
                        body:
                        """
                        The Calc tab shows the current week, one row per day. Each row gives you three numbers:

                        • **Consumed** — what you've logged eating that day
                        • **Burned** — workouts (manual + HealthKit)
                        • **Remaining** — calories left in *today's* budget given how the rest of the week is going

                        Remaining is the headline number. It says how many more calories you can eat *right now* and still be on plan. Drops when you log food, rises when you log a workout. It does *not* pre-credit a workout you haven't done. If you went over yesterday it pulls from today; if you ate light, today's Remaining grows. The number always reflects your *current* variance across the week, not where you started this morning.

                        Below the days you'll find the **Remaining This Week** card — the headline number for the whole tab. It's how many calories you have left to eat through the rest of the week *if you stick to your planned workouts*.

                        The math (tap the card to expand it):

                        • **Allocated net calories** — your weekly budget (daily net × 7).
                        • **− Actual consumed** — everything you've logged eating this week.
                        • **+ Actual exercise** — workouts you've already done this week.
                        • **+ Projected exercise** — the burn you're planning to do on the remaining days.

                        Because Projected Exercise is in there, the number assumes you'll actually do the planned workouts. Skip a workout and Projected Exercise drops, so Remaining shrinks. Do an extra workout and Actual Exercise climbs, so Remaining grows. The hero number is always live with what you've actually logged.

                        If you're over on the last day of the week, it's not the end of the world. Reset Sunday and go again.
                        """
                    )

                    section(
                        title: "Regular days vs bonus days",
                        icon: "calendar",
                        body:
                        """
                        Settings → Week split lets you pick something like **5/2** — five regular days, two bonus days.

                        Regular days have the tighter eating target. Hit your regular-day gross, burn the planned workout, build the cushion. Bonus days have a higher target — that's where you spend what you saved.

                        The split is just what the math *targets* per day — the app never stops you from eating. I order regular days first because earning the headroom before spending it is what makes a bonus day feel like a reward instead of a guilt trip.
                        """
                    )

                    section(
                        title: "Quick Add",
                        icon: "bolt.fill",
                        iconTint: .orange,
                        body:
                        """
                        Quick Add is the fast lane. From the Calc tab, tap Quick Add and you'll see:

                        • **Quick items** — anything from My Foods that you marked with the ⚡ bolt. Use it for things you eat the same way every time — a protein bar, your usual coffee, a daily shake.
                        • **Manual entry** — type a name, calories, and macros for one-off things you'd never bother saving.

                        One tap to log; no searching required.
                        """
                    )

                    section(
                        title: "Daily log",
                        icon: "list.bullet.clipboard",
                        body:
                        """
                        Tap any day on the Calc tab to open its daily log. Food is grouped by meal — Breakfast, Lunch, Dinner, Snacks — with calorie and macro totals shown on each meal header. Workouts (Apple Health + anything manual) sit below. At the bottom, a **Summary** shows exactly how that day's Remaining was calculated, including planned vs actual exercise so you can see *why* the number says what it says.

                        Sections start collapsed for a clean view. Logging an item live expands its section automatically.

                        **Tip:** for the most accurate plan, log food by weight when you can — grams beat eyeballed portions every time. The more precise each entry, the better the math reflects what you're actually eating.
                        """
                    )

                    section(
                        title: "Logging anything",
                        icon: "plus.circle",
                        body:
                        """
                        The Log button on the daily log opens a sheet with two areas:

                        • **My Foods + Recents** — pick from your saved list or things you've logged before. One tap, done.
                        • **Search tab** — four ways to find anything else:
                          • **Scan** a barcode (Open Food Facts).
                          • **Photo** — AI estimates calories + macros from a picture.
                          • **Describe** — type "Five Guys cheeseburger" and AI does the math.
                          • **Manual entry** — type the numbers yourself when you already know them.

                        Photo and Describe send your input to Anthropic's Claude through our proxy — the app asks once before enabling AI features, and you can turn them off any time in Settings → Privacy.

                        The meal selector at the top of the sheet decides where the item lands. The search bar at the bottom hunts across your foods, your recents, and the USDA national food database in one place.

                        For exercise, Apple Health pulls active-energy automatically once you authorize it. Add manual workouts for anything Health misses — gym session without the watch, gardening, whatever.
                        """
                    )

                    section(
                        title: "Progress",
                        icon: "chart.line.uptrend.xyaxis",
                        body:
                        """
                        Progress is the look-back. Pick a range — 7, 14, 30, 60, 90, 180 days, a year, or a custom window — and you'll see your weight chart, current-weight summary, and the history rows for every metric (net calories, calories, macros, exercise, steps) averaged over the period.

                        The weight chart includes a **trend line** — a regression fit through every weigh-in. Day-to-day weight bounces ±2 lbs on water alone, which makes it hard to tell if the plan is actually working. The trend line filters that noise so you can see the real slope and decide whether to tweak the plan.

                        Use **Include today** to drop today's partial data when it's pulling the short-range averages around — today's still-developing numbers can skew a 7- or 14-day day-avg hard. Flip it off, look at the settled history, then flip it back on for live tracking.

                        This is where maintenance happens. Trend creeping up? Drop the net a little, give it two weeks, look again.
                        """
                    )

                    section(
                        title: "My Foods",
                        icon: "fork.knife",
                        body:
                        """
                        Save the things you eat regularly so you stop re-searching them every week.

                        • Tap the ⚡ bolt on any food to mark it as **Quick Add**. Those surface for one-tap logging from the Calc tab.
                        • Add **tags** to organize your list — make whatever categories work for you (Breakfast, Prep, Snacks, Treats) and assign them to your saved items.
                        • Filter the list by tag from the My Foods toolbar.
                        """
                    )

                    section(
                        title: "Tuning the plan",
                        icon: "slider.horizontal.3",
                        body:
                        """
                        Settings is where the targets live:

                        • **Target Daily Net** — your weekly goal ÷ 7. Lower to lose faster, raise to maintain.
                        • **Daily eating goal (regular days)** — calories eaten before exercise on a regular day.
                        • **Workout goal** — what you commit to burn on a regular day. Without it, the eating target eats too much of the weekly budget.
                        • **Week split** — how many bank vs bonus days.
                        • **Week starts on** — so bonus days land at the end of *your* week.

                        Changes apply going forward only. Past weeks keep the goals that were active at the time, so the history stays honest about what you were aiming for then.
                        """
                    )

                    Text("That's the whole system. The math runs the plan; you just decide.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("How it works")
            .navigationBarTitleDisplayMode(.large)
            .onReceive(NotificationCenter.default.publisher(for: .scrollToTop)) { _ in
                withAnimation { proxy.scrollTo("top", anchor: .top) }
            }
            }
        }
    }

    // MARK: - Building blocks

    private var bigIdeaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(.tint)
                Text("Average the week, not the day")
                    .font(.headline)
            }
            Text(
                """
                Lose weight — or hold a weight — without the all-or-nothing trap that kills most diets. CalorieCalc tracks your calories in and out and averages the **week**, so one real dinner doesn't undo five disciplined days. Set a daily net goal, log food and workouts, and the Calc tab shows exactly how many calories you have left to eat right now. Same system I used to lose 60+ lbs — twice — and now use to stay there.
                """
            )
            .font(.subheadline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [.accentColor.opacity(0.22), .accentColor.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    private func section(title: String, icon: String, iconTint: Color? = nil, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
                Text(title)
                    .font(.headline)
            }
            sectionBody(body)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    /// Renders a section body that may include "• "-prefixed bullet lists. Each contiguous
    /// run of bullet lines becomes a stack of hanging-indent rows so wrapped lines align
    /// to the right of the bullet, like a proper list. Sub-bullets (lines with leading
    /// spaces before "• ") indent further. Plain paragraphs stay as Markdown `Text` so
    /// existing **bold** spans continue to render.
    @ViewBuilder
    private func sectionBody(_ body: String) -> some View {
        let paragraphs = body.components(separatedBy: "\n\n")
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                let lines = paragraph.split(separator: "\n", omittingEmptySubsequences: true)
                let parsed = lines.map(parseBulletLine)
                if !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(parsed.enumerated()), id: \.offset) { _, item in
                            if let item {
                                bulletRow(item.text, level: item.level)
                            }
                        }
                    }
                } else {
                    Text(LocalizedStringKey(paragraph))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Returns (nesting level, content after the bullet) or nil if the line isn't a bullet.
    /// Two leading spaces in the source string == one nesting level.
    private func parseBulletLine(_ line: Substring) -> (level: Int, text: String)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let trimmed = line.dropFirst(leadingSpaces)
        guard trimmed.hasPrefix("• ") else { return nil }
        return (leadingSpaces / 2, String(trimmed.dropFirst(2)))
    }

    private func bulletRow(_ text: String, level: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            boltAwareText(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(level) * 18)
    }

    /// Replaces literal `⚡` characters with an inline orange SF Symbol bolt so the icon
    /// in prose matches the favorite/Quick Add bolt elsewhere. The emoji is always
    /// rendered yellow by the OS regardless of SwiftUI styling — the Image replacement
    /// is the only way to actually color it. `bolt` is built as a `Text` (not a styled
    /// `View`) so it interpolates cleanly into the outer `Text` without falling through
    /// to the deprecated unlocalized-description path.
    private func boltAwareText(_ raw: String) -> Text {
        guard raw.contains("⚡") else {
            return Text(LocalizedStringKey(raw))
        }
        let parts = raw.components(separatedBy: "⚡")
        let bolt = Text("\(Image(systemName: "bolt.fill"))").foregroundStyle(.orange)
        var result = Text(LocalizedStringKey(parts[0]))
        for part in parts.dropFirst() {
            result = Text("\(result)\(bolt)\(Text(LocalizedStringKey(part)))")
        }
        return result
    }
}
