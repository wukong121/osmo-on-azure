"""Shared helpers: connect to the AzureML workspace with the pod's Workload Identity.

Every OSMO workflow pod runs as the osmo-workflow service account, which is federated with the
OSMO managed identity, so DefaultAzureCredential picks up the projected token automatically.
The workspace is identified by AML_SUBSCRIPTION_ID / AML_RESOURCE_GROUP / AML_WORKSPACE.
"""

from __future__ import annotations

import os

from azure.ai.ml import MLClient
from azure.identity import DefaultAzureCredential


def credential() -> DefaultAzureCredential:
    return DefaultAzureCredential(exclude_interactive_browser_credential=True)


def ml_client() -> MLClient:
    return MLClient(
        credential(),
        subscription_id=os.environ["AML_SUBSCRIPTION_ID"],
        resource_group_name=os.environ["AML_RESOURCE_GROUP"],
        workspace_name=os.environ["AML_WORKSPACE"],
    )


def setup_mlflow(client: MLClient, experiment: str):
    """Point MLflow at the workspace tracking server and select the experiment."""
    import mlflow

    uri = client.workspaces.get(client.workspace_name).mlflow_tracking_uri
    mlflow.set_tracking_uri(uri)
    mlflow.set_experiment(experiment)
    return mlflow


def workflow_tags() -> dict[str, str]:
    """Tags that link AzureML records back to the OSMO workflow that produced them."""
    tags = {"orchestrator": "osmo"}
    for env, key in (("OSMO_WORKFLOW_ID", "osmo_workflow_id"), ("OSMO_URL", "osmo_url")):
        if os.environ.get(env):
            tags[key] = os.environ[env]
    return tags
