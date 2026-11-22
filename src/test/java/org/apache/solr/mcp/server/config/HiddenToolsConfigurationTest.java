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

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import io.modelcontextprotocol.server.McpServerFeatures;
import io.modelcontextprotocol.spec.McpSchema;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.DisabledInNativeImage;
import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.mock.env.MockEnvironment;

/** Unit tests for {@link HiddenToolsConfiguration}: tools are only hidden when configured. */
// Mockito mocks the final MCP SDK records; ByteBuddy proxies don't survive GraalVM.
@DisabledInNativeImage
class HiddenToolsConfigurationTest {

  private static McpServerFeatures.SyncToolSpecification spec(String name) {
    McpSchema.Tool tool = mock(McpSchema.Tool.class);
    when(tool.name()).thenReturn(name);
    McpServerFeatures.SyncToolSpecification spec =
        mock(McpServerFeatures.SyncToolSpecification.class);
    when(spec.tool()).thenReturn(tool);
    return spec;
  }

  private static List<String> names(Object list) {
    return ((List<?>) list)
        .stream().map(s -> ((McpServerFeatures.SyncToolSpecification) s).tool().name()).toList();
  }

  private static BeanPostProcessor processor(MockEnvironment env) {
    return HiddenToolsConfiguration.hiddenToolsPostProcessor(env);
  }

  private final List<McpServerFeatures.SyncToolSpecification> tools =
      List.of(
          spec("search"), spec("index-json-documents"), spec("create-alias"), spec("get-schema"));

  @Test
  void leavesToolsAloneByDefault() {
    Object result = processor(new MockEnvironment()).postProcessAfterInitialization(tools, "tools");
    assertSame(tools, result);
  }

  @Test
  void readOnlyHidesEveryWriteTool() {
    var env = new MockEnvironment().withProperty("solr.mcp.read-only", "true");
    Object result = processor(env).postProcessAfterInitialization(tools, "tools");
    assertEquals(List.of("search", "get-schema"), names(result));
  }

  @Test
  void hiddenToolsHidesNamedToolsOnly() {
    var env = new MockEnvironment().withProperty("solr.mcp.hidden-tools", " search , get-schema ");
    Object result = processor(env).postProcessAfterInitialization(tools, "tools");
    assertEquals(List.of("index-json-documents", "create-alias"), names(result));
  }

  @Test
  void ignoresBeansThatAreNotToolLists() {
    var env = new MockEnvironment().withProperty("solr.mcp.read-only", "true");
    List<String> other = List.of("search", "create-alias");
    assertSame(other, processor(env).postProcessAfterInitialization(other, "other"));
    assertSame("x", processor(env).postProcessAfterInitialization("x", "str"));
  }
}
