// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

use crate::{
    DiscoveredProvider, DiscoveryContext, ProviderError, ProviderPlugin, RealDiscoveryContext,
};

/// Provider plugin for a local or remote Ollama instance.
///
/// Unlike other providers, `OllamaProvider` requires no credentials. Discovery
/// checks for `OLLAMA_BASE_URL` or `OLLAMA_HOST` in the environment and, if
/// found, returns a config-only `DiscoveredProvider`. Onboarding (detecting a
/// running Ollama and listing available models) is handled by `nemoclaw onboard`.
pub struct OllamaProvider;

impl OllamaProvider {
    fn discover_with_context(
        context: &dyn DiscoveryContext,
    ) -> Result<Option<DiscoveredProvider>, ProviderError> {
        let base_url = context
            .env_var("OLLAMA_BASE_URL")
            .or_else(|| context.env_var("OLLAMA_HOST"));

        let Some(url) = base_url else {
            return Ok(None);
        };

        if url.trim().is_empty() {
            return Ok(None);
        }

        let mut discovered = DiscoveredProvider::default();
        discovered.config.insert("OLLAMA_BASE_URL".to_string(), url);
        Ok(Some(discovered))
    }
}

impl ProviderPlugin for OllamaProvider {
    fn id(&self) -> &'static str {
        "ollama"
    }

    fn discover_existing(&self) -> Result<Option<DiscoveredProvider>, ProviderError> {
        Self::discover_with_context(&RealDiscoveryContext)
    }
}

#[cfg(test)]
mod tests {
    use super::OllamaProvider;
    use crate::test_helpers::MockDiscoveryContext;

    #[test]
    fn returns_none_when_no_env_vars_set() {
        let ctx = MockDiscoveryContext::new();
        let result =
            OllamaProvider::discover_with_context(&ctx).expect("discovery should not error");
        assert!(result.is_none());
    }

    #[test]
    fn returns_some_with_ollama_base_url() {
        let ctx =
            MockDiscoveryContext::new().with_env("OLLAMA_BASE_URL", "http://ollama.example:11434");
        let discovered = OllamaProvider::discover_with_context(&ctx)
            .expect("discovery should not error")
            .expect("should discover provider");
        assert_eq!(
            discovered.config.get("OLLAMA_BASE_URL"),
            Some(&"http://ollama.example:11434".to_string())
        );
        assert!(discovered.credentials.is_empty());
    }

    #[test]
    fn returns_some_with_ollama_host_fallback() {
        let ctx = MockDiscoveryContext::new().with_env("OLLAMA_HOST", "http://localhost:11434");
        let discovered = OllamaProvider::discover_with_context(&ctx)
            .expect("discovery should not error")
            .expect("should discover provider");
        assert_eq!(
            discovered.config.get("OLLAMA_BASE_URL"),
            Some(&"http://localhost:11434".to_string())
        );
    }

    #[test]
    fn ollama_base_url_takes_priority_over_ollama_host() {
        let ctx = MockDiscoveryContext::new()
            .with_env("OLLAMA_BASE_URL", "http://remote:11434")
            .with_env("OLLAMA_HOST", "http://localhost:11434");
        let discovered = OllamaProvider::discover_with_context(&ctx)
            .expect("discovery should not error")
            .expect("should discover provider");
        assert_eq!(
            discovered.config.get("OLLAMA_BASE_URL"),
            Some(&"http://remote:11434".to_string())
        );
    }
}
