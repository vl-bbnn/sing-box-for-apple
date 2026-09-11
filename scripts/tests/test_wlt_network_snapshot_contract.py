"""Source contract for privacy-safe active-data radio diagnostics."""

from pathlib import Path
import unittest


SOURCE = Path(__file__).parents[2] / "SFI" / "WLTDeviceControl.swift"


class WLTNetworkSnapshotContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text()
        cls.schema = cls.source.split("private struct NetworkSnapshot", 1)[1].split(
            "private struct Outcome", 1
        )[0]
        cls.capture = cls.source.split(
            "private func captureNetworkSnapshot()", 1
        )[1].split("private func pruneResults", 1)[0]

    def test_active_data_service_selects_its_radio_without_exporting_raw_identifier(self):
        self.assertIn("let dataServiceIdentifier = telephony.dataServiceIdentifier", self.capture)
        self.assertIn("dataServiceIdentifier.flatMap", self.capture)
        self.assertIn("radioByService[identifier]", self.capture)
        self.assertIn('radioTechnologySource = "active_data_service"', self.capture)
        self.assertIn("let dataServiceIDHash: String?", self.schema)
        self.assertIn('case dataServiceIDHash = "data_service_id_hash"', self.schema)
        self.assertNotIn("dataServiceIdentifier", self.schema)
        self.assertNotIn('"data_service_identifier"', self.source)

    def test_existing_pseudonymous_service_hash_contract_is_retained(self):
        self.assertIn("SHA256.hash(data: data)", self.capture)
        self.assertIn(".prefix(6)", self.capture)
        self.assertIn("dataServiceIDHash: dataServiceIDHash", self.capture)

    def test_multi_service_fallback_stays_unknown_when_active_service_is_unresolved(self):
        self.assertIn("radioByService.count == 1", self.capture)
        self.assertIn('radioTechnology = "unknown"', self.capture)
        self.assertIn('radioTechnologySource = "unavailable"', self.capture)
        self.assertNotIn("joined(separator:", self.capture)

    def test_observed_radios_are_sanitized_unique_and_sorted(self):
        self.assertIn("Self.sanitizedRadioTechnology", self.capture)
        self.assertIn("Array(Set(", self.capture)
        self.assertIn(")).sorted()", self.capture)
        self.assertIn('case radioTechnologies = "radio_technologies"', self.schema)
        self.assertIn(
            'case radioTechnologySource = "radio_technology_source"', self.schema
        )

    def test_transport_and_service_count_semantics_are_preserved(self):
        for required in (
            "cellular: path.usesInterfaceType(.cellular)",
            "wifi: path.usesInterfaceType(.wifi)",
            "max(\n            radioByService.count,",
            "telephony.serviceSubscriberCellularProviders?.count ?? 0",
        ):
            self.assertIn(required, self.capture)
        self.assertNotIn("radioTechnology ==", self.capture)


if __name__ == "__main__":
    unittest.main()
