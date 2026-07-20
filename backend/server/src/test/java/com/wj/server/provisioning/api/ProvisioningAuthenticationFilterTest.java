package com.wj.server.provisioning.api;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.wj.server.config.ProvisioningProperties;
import jakarta.servlet.FilterChain;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

class ProvisioningAuthenticationFilterTest {

    @Test
    void rejectsMissingKeyBeforeControllerBinding() throws Exception {
        var filter = new ProvisioningAuthenticationFilter(
            new ProvisioningProperties(true, "k".repeat(32)), new ObjectMapper());
        var request = new MockHttpServletRequest("POST", "/internal/admin/devices");
        request.setRemoteAddr("127.0.0.1");
        var response = new MockHttpServletResponse();
        FilterChain chain = (req, res) -> { throw new AssertionError("filter chain must not continue"); };

        filter.doFilter(request, response, chain);

        assertThat(response.getStatus()).isEqualTo(404);
        assertThat(response.getContentAsString()).contains("RESOURCE_NOT_FOUND");
    }
}
