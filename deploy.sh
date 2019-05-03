#!/bin/bash
docker login -u $DOCKERUSER -p $DOCKERPASS
docker push bsycorp/kind
