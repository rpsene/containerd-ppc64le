#!/bin/bash

: '
    Copyright (C) 2019 IBM Corporation
    Licensed under the Apache License, Version 2.0 (the “License”);
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an “AS IS” BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

    Contributors:
        * Rafael Sene <rpsene@gmail.com>

    README: This script builds and instals containerd on Ubuntu (ppc64le).

    containerd is an industry-standard container runtime with an emphasis 
    on simplicity, robustness and portability
'

# install required dependencies
export DEBIAN_FRONTEND=noninteractive
apt-get update -yq
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -yq
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -yq build-essential btrfs-tools libseccomp-dev unzip pkg-config


# configure a GO development environment
git clone https://github.com/rpsene/goconfig.git
source ./goconfig/go.sh install

cd

# install protoc
wget https://github.com/protocolbuffers/protobuf/releases/download/v3.7.1/protoc-3.7.1-linux-ppcle_64.zip
unzip ./protoc-3.7.1-linux-ppcle_64.zip -d protoc-3.7.1
mv ./protoc-3.7.1/bin/protoc /usr/local/bin

# build runc
go get github.com/opencontainers/runc
cd $GOPATH/src/github.com/opencontainers/runc
make
make install

# build containerid
go get github.com/containerd/containerd
cd $GOPATH/src/github.com/containerd/containerd
make
make install
make integration

# containerd service
cp ./containerd.service /etc/systemd/system/
chmod 700 /etc/systemd/system/containerd.service
systemctl enable containerd.service
service containerd start
#service containerd status
containerd config default > /etc/containerd/config.toml


# run an example
cd $GOPATH/src
echo '
package main

import (
	"context"
	"fmt"
	"log"
	"syscall"
	"time"

	"github.com/containerd/containerd"
	"github.com/containerd/containerd/cio"
	"github.com/containerd/containerd/oci"
	"github.com/containerd/containerd/namespaces"
)

func main() {
	if err := redisExample(); err != nil {
		log.Fatal(err)
	}
}

func redisExample() error {
	// create a new client connected to the default socket path for containerd
	client, err := containerd.New("/run/containerd/containerd.sock")
	if err != nil {
		return err
	}
	defer client.Close()

	// create a new context with an "example" namespace
	ctx := namespaces.WithNamespace(context.Background(), "example")

	// pull the redis image from DockerHub
	image, err := client.Pull(ctx, "docker.io/library/redis:alpine", containerd.WithPullUnpack)
	if err != nil {
		return err
	}

	// create a container
	container, err := client.NewContainer(
		ctx,
		"redis-server",
		containerd.WithImage(image),
		containerd.WithNewSnapshot("redis-server-snapshot", image),
		containerd.WithNewSpec(oci.WithImageConfig(image)),
	)
	if err != nil {
		return err
	}
	defer container.Delete(ctx, containerd.WithSnapshotCleanup)

	// create a task from the container
	task, err := container.NewTask(ctx, cio.NewCreator(cio.WithStdio))
	if err != nil {
		return err
	}
	defer task.Delete(ctx)

	// make sure we wait before calling start
	exitStatusC, err := task.Wait(ctx)
	if err != nil {
		fmt.Println(err)
	}

	// call start on the task to execute the redis server
	if err := task.Start(ctx); err != nil {
		return err
	}

	// sleep for a lil bit to see the logs
	time.Sleep(3 * time.Second)

	// kill the process and get the exit status
	if err := task.Kill(ctx, syscall.SIGTERM); err != nil {
		return err
	}

	// wait for the process to fully exit and print out the exit status

	status := <-exitStatusC
	code, _, err := status.Result()
	if err != nil {
		return err
	}
	fmt.Printf("redis-server exited with status: %d\n", code)

	return nil
}
' >> main.go

go build main.go
./main
