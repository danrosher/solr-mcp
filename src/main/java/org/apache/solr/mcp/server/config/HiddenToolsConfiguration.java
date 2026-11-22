/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.apache.solr.mcp.server.config;

import io.modelcontextprotocol.server.McpServerFeatures;
import io.modelcontextprotocol.server.McpStatelessServerFeatures;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;

/**
 * Removes selected tools from the MCP tool list so they are never advertised to clients.
 *
 * <p>Off by default. Enable either or both of:
 *
 * <ul>
 *   <li>{@code solr.mcp.read-only=true} (env {@code SOLR_MCP_READ_ONLY}) hides every tool that
 *       writes to Solr: the four {@code index-*} tools, {@code add-fields}, {@code
 *       add-field-types}, {@code create-collection}, {@code create-alias} and {@code delete-alias}.
 *   <li>{@code solr.mcp.hidden-tools=a,b} (env {@code SOLR_MCP_HIDDEN_TOOLS}) hides the named
 *       tools.
 * </ul>
 *
 * <p>This is a tidiness control, not a security boundary: it only changes what the server lists.
 * Enforce read-only access at the network layer (see {@code deploy/readonly-proxy}). The read-only
 * list below must be updated if the server gains new write tools.
 *
 * <p>The tool lists are filtered where Spring AI hands them to the MCP server, so this covers both
 * the stateful (STDIO) and stateless (HTTP) transports without editing any tool class.
 */
@Configuration(proxyBeanMethods = false)
public class HiddenToolsConfiguration {

  /** Every tool that modifies Solr. */
  static final Set<String> WRITE_TOOLS =
      Set.of(
          "index-json-documents",
          "index-csv-documents",
          "index-xml-documents",
          "index-markdown-documents",
          "add-fields",
          "add-field-types",
          "create-collection",
          "create-alias",
          "delete-alias");

  @Bean
  static BeanPostProcessor hiddenToolsPostProcessor(Environment environment) {
    Set<String> hidden = new HashSet<>();
    if (environment.getProperty("solr.mcp.read-only", Boolean.class, false)) {
      hidden.addAll(WRITE_TOOLS);
    }
    String extra = environment.getProperty("solr.mcp.hidden-tools", "");
    Arrays.stream(extra.split(","))
        .map(String::trim)
        .filter(s -> !s.isEmpty())
        .forEach(hidden::add);
    return new HiddenToolsPostProcessor(Set.copyOf(hidden));
  }

  /** Filters any bean that is a list of MCP tool specifications. */
  static final class HiddenToolsPostProcessor implements BeanPostProcessor {

    private final Set<String> hidden;

    HiddenToolsPostProcessor(Set<String> hidden) {
      this.hidden = hidden;
    }

    @Override
    public Object postProcessAfterInitialization(Object bean, String beanName) {
      if (hidden.isEmpty() || !(bean instanceof List<?> list) || list.isEmpty()) {
        return bean;
      }
      if (!list.stream().allMatch(HiddenToolsPostProcessor::isToolSpecification)) {
        return bean;
      }
      return list.stream().filter(spec -> !hidden.contains(toolName(spec))).toList();
    }

    private static boolean isToolSpecification(Object o) {
      return o instanceof McpServerFeatures.SyncToolSpecification
          || o instanceof McpServerFeatures.AsyncToolSpecification
          || o instanceof McpStatelessServerFeatures.SyncToolSpecification
          || o instanceof McpStatelessServerFeatures.AsyncToolSpecification;
    }

    private static String toolName(Object spec) {
      return switch (spec) {
        case McpServerFeatures.SyncToolSpecification s -> s.tool().name();
        case McpServerFeatures.AsyncToolSpecification s -> s.tool().name();
        case McpStatelessServerFeatures.SyncToolSpecification s -> s.tool().name();
        case McpStatelessServerFeatures.AsyncToolSpecification s -> s.tool().name();
        default -> "";
      };
    }
  }
}
