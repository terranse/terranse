"""Mock 1Password lookup plugin for Molecule testing.

This plugin returns predictable test values instead of calling the real
1Password CLI, allowing templates with onepassword lookups to be tested.
"""

from ansible.plugins.lookup import LookupBase
from ansible.errors import AnsibleError


class LookupModule(LookupBase):
    """Mock 1Password lookup that returns test values."""

    def run(self, terms, variables=None, **kwargs):
        """Return mock values for any 1Password lookup."""
        results = []

        for term in terms:
            # Generate a predictable mock value based on the item name and field
            field = kwargs.get('field', 'password')
            vault = kwargs.get('vault', 'default')

            # Create a deterministic mock value
            mock_value = f"mock_{field}_{term.replace(' ', '_').lower()}"

            results.append(mock_value)

        return results
