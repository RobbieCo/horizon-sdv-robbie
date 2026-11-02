# Copyright (c) 2026 Accenture, All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Multi-arch: defaults build linux/amd64 (production unchanged). Local desktop
# builds pass --platform (e.g. linux/arm64) so pods run native, not emulated.
ARG TARGETOS=linux
ARG TARGETARCH=amd64
FROM --platform=${BUILDPLATFORM:-linux/amd64} golang:1.27.2-alpine AS builder
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o /horizon-api .

FROM --platform=${TARGETOS}/${TARGETARCH} alpine:3.19
RUN apk --no-cache add ca-certificates
COPY --from=builder --chown=nobody:nobody /horizon-api /horizon-api
USER nobody
ENTRYPOINT ["/horizon-api"]
