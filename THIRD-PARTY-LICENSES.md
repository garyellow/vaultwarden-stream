# Third-Party Licenses

This project integrates the following open source software. Each component is used in compliance with its respective license.

---

## Vaultwarden

**Project:** https://github.com/dani-garcia/vaultwarden
**License:** GNU Affero General Public License v3.0 (AGPL-3.0)
**Description:** Unofficial Bitwarden® compatible password manager server written in Rust

This Docker image is built on top of the official Vaultwarden Alpine image. Vaultwarden is licensed under AGPL-3.0, which requires:

- The complete source code must be made available to users who interact with the software over a network
- Any modifications must be released under the same AGPL-3.0 license
- Appropriate copyright and license notices must be preserved

**Note:** This project does not modify Vaultwarden's source code. We use the official Vaultwarden Docker image as-is and add orchestration scripts.

**Full License:** https://github.com/dani-garcia/vaultwarden/blob/main/LICENSE.txt

---

## Litestream

**Project:** https://github.com/benbjohnson/litestream
**License:** Apache License 2.0
**Description:** Streaming replication for SQLite

Copyright (c) Ben Johnson

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

**Full License:** https://github.com/benbjohnson/litestream/blob/main/LICENSE

---

## rclone

**Project:** https://github.com/rclone/rclone
**License:** MIT License
**Description:** "rsync for cloud storage" - sync files to and from cloud storage

Copyright (C) 2012 by Nick Craig-Wood http://www.craig-wood.com/nick/

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

**Full License:** https://github.com/rclone/rclone/blob/master/COPYING

---

## Additional Notes

### AGPL-3.0 Compliance (Vaultwarden)

This project is in compliance with the AGPL-3.0 license requirements:

1. **Source Code Availability:** The underlying Vaultwarden source code is publicly available at https://github.com/dani-garcia/vaultwarden
2. **No Modifications:** We do not modify Vaultwarden's source code; we use the official Docker image
3. **License Preservation:** All copyright notices and license information are preserved
4. **Network Access:** Users interacting with Vaultwarden deployed using this project have the same access to source code as they would with the official Vaultwarden deployment

### License Compatibility

The combination of licenses used in this project is compatible:

- **MIT (this project):** Permissive, compatible with all other licenses
- **MIT (rclone):** Permissive, compatible with all other licenses
- **Apache 2.0 (Litestream):** Permissive, compatible with AGPL-3.0
- **AGPL-3.0 (Vaultwarden):** Copyleft, applies to Vaultwarden itself but not to separate programs (like our orchestration scripts) that interact with it

This project's orchestration scripts are separate works that automate deployment and do not create a derivative work of Vaultwarden.

---

For the complete and authoritative license texts, please refer to the official repositories linked above.
