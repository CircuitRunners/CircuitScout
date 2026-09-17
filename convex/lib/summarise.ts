import { climbPoints, countedTeleopFuel, uncountedTeleopFuel } from "./scoring";
import type { Doc } from "../_generated/dataModel";

export type Summary = {
  reportCount: number;
  /**
   * Reports behind the rating averages. Lower than reportCount when the robot
   * broke in some matches — those are left out of driver, defense, accuracy
   * and BPS, so the two counts must be readable separately.
   */
  ratedReportCount: number;
  avgAutoFuel: number;
  avgTeleopFuel: number;
  avgUncountedFuel: number;
  avgEndgameFuel: number;
  avgTotalFuel: number;
  avgClimbPoints: number;
  /** Fuel passed to partners: teleop and endgame, neutral and full field. */
  avgPassing: number;
  avgDriver: number;
  avgDefense: number;
  avgAccuracy: number;
  avgBps: number;
  avgAdjustedBps: number;
  bpsReportCount: number;
  minTotalFuel: number;
  maxTotalFuel: number;
  brokeCount: number;
  inconsistentCount: number;
};

export const EMPTY_SUMMARY: Summary = {
  reportCount: 0, ratedReportCount: 0, avgAutoFuel: 0, avgTeleopFuel: 0,
  avgUncountedFuel: 0, avgEndgameFuel: 0, avgTotalFuel: 0, avgClimbPoints: 0,
  avgPassing: 0, avgDriver: 0, avgDefense: 0, avgAccuracy: 0, avgBps: 0,
  avgAdjustedBps: 0, bpsReportCount: 0, minTotalFuel: 0, maxTotalFuel: 0,
  brokeCount: 0, inconsistentCount: 0,
};

const mean = (xs: number[]) =>
  xs.length === 0 ? 0 : xs.reduce((a, b) => a + b, 0) / xs.length;

/** One report's derived numbers, given whether its alliance won auto. */
export function derive(report: Doc<"matchReports">, isAutoWinner: boolean | null) {
  const counted =
    isAutoWinner === null
      ? Object.values(report.teleop.byShift).reduce((a, b) => a + b, 0)
      : countedTeleopFuel(report.teleop.byShift, isAutoWinner);
  const dead =
    isAutoWinner === null ? 0 : uncountedTeleopFuel(report.teleop.byShift, isAutoWinner);

  return {
    counted,
    dead,
    total: report.auto.fuel + counted + report.endgame.fuel,
    climb: climbPoints(report.auto.climbL1, report.endgame.climb),
    // Both phases, both distances. A robot that feeds all match scores little
    // fuel itself, and this is the number that says so.
    passing:
      report.teleop.passedNeutral + report.teleop.passedFullField
      + report.endgame.passedNeutral + report.endgame.passedFullField,
  };
}

export function summarise(
  entries: { report: Doc<"matchReports">; isAutoWinner: boolean | null }[],
): Summary {
  if (entries.length === 0) return { ...EMPTY_SUMMARY };

  const auto: number[] = [], tele: number[] = [], dead: number[] = [];
  const end: number[] = [], totals: number[] = [], climbs: number[] = [];
  const passing: number[] = [];
  const drv: number[] = [], def: number[] = [], acc: number[] = [], bps: number[] = [];
  const adjusted: number[] = [];
  let broke = 0, inconsistent = 0;

  for (const { report, isAutoWinner } of entries) {
    const d = derive(report, isAutoWinner);
    auto.push(report.auto.fuel);
    tele.push(d.counted);
    dead.push(d.dead);
    end.push(report.endgame.fuel);
    totals.push(d.total);
    climbs.push(d.climb);
    passing.push(d.passing);

    // A robot that broke spent part of the match not driving, not defending
    // and not shooting. Rating that is rating the breakdown twice, since
    // brokeCount already records it, so those four averages skip the match.
    // Fuel stays in: what it scored before it died actually happened.
    if (report.ratings.broke) {
      broke += 1;
    } else {
      drv.push(report.ratings.driver);
      def.push(report.ratings.defense);
      acc.push(report.ratings.accuracy);
      // Reports written before avgBps existed must not average in as zero.
      if (report.avgBps !== undefined) {
        bps.push(report.avgBps);
        // Accuracy is a percentage; the adjusted rate is per report, then averaged.
        adjusted.push(report.avgBps * (report.ratings.accuracy / 100));
      }
    }
    if (report.ratings.inconsistent) inconsistent += 1;
  }

  return {
    reportCount: entries.length,
    ratedReportCount: drv.length,
    avgAutoFuel: mean(auto),
    avgTeleopFuel: mean(tele),
    avgUncountedFuel: mean(dead),
    avgEndgameFuel: mean(end),
    avgTotalFuel: mean(totals),
    avgClimbPoints: mean(climbs),
    avgPassing: mean(passing),
    avgDriver: mean(drv),
    avgDefense: mean(def),
    avgAccuracy: mean(acc),
    avgBps: mean(bps),
    avgAdjustedBps: mean(adjusted),
    bpsReportCount: bps.length,
    minTotalFuel: Math.min(...totals),
    maxTotalFuel: Math.max(...totals),
    brokeCount: broke,
    inconsistentCount: inconsistent,
  };
}
