#!/bin/sh
# Port forward and connect to postgres
# $1: namespace
kubectl -n $1  port-forward service/commons-postgresql 5432:5432
