module OpenTelemetry.AllSignalsSnapshotSpec (spec) where

import OpenTelemetry.AllSignalsSnapshot (allSignalsSnapshotGolden)
import Test.Hspec


spec :: Spec
spec =
  describe "All signals snapshot" $
    it "captures traces, logs, and metrics in a deterministic snapshot" $
      allSignalsSnapshotGolden
