/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License").
 * You may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package integration;

public enum DebugEnv {
  VSCODE,
  TERMINAL;

  public static DebugEnv fromString(String s) {
    if (s == null || s.equals("")) {
      return null;
    }

    s = s.toLowerCase();
    if (s.equals("vscode")) {
      return VSCODE;
    } else if (s.equals("terminal")) {
      return TERMINAL;
    } else {
      return null;
    }
  }

  public static DebugEnv fromEnv() {
    String envVar = System.getenv("DEBUG_ENV");
    if (envVar == null || envVar.equals("")) {
      return VSCODE;
    }

    DebugEnv debugEnv = DebugEnv.fromString(envVar);
    if (debugEnv == null) {
      String errorMessage = "Invalid environment variable setting for DEBUG_ENV: '%s'. Valid values are 'VSCODE' or 'TERMINAL'.";
      throw new RuntimeException(String.format(errorMessage, envVar));
    }

    return debugEnv;
  }
}
