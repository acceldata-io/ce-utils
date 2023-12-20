#!/bin/bash

# Check if all required arguments are provided
if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <ambari-server> <port> <cluster-name> <username> <password>"
    exit 1
fi

# Command-line arguments
AMBARI_SERVER="$1"
PORT="$2"
CLUSTER_NAME="$3"
USERNAME="$4"
PASSWORD="$5"

# API endpoint for request schedules
API_ENDPOINT="http://${AMBARI_SERVER}:${PORT}/api/v1/clusters/${CLUSTER_NAME}/request_schedules"

PAYLOAD='[
   {
      "RequestSchedule":{
         "batch":[
            {
               "requests":[
                  {
                     "order_id":1,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"HDFS Service Check (batch 1 of 13)",
                           "command":"HDFS_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"HDFS"
                           }
                        ]
                     }
                  },
                  {
                     "order_id":2,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"YARN Service Check (batch 2 of 13)",
                           "command":"YARN_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"YARN"
                           }
                        ]
                     }
                  },
                  {
                     "order_id":3,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"MapReduce Service Check (batch 3 of 13)",
                           "command":"MAPREDUCE2_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"MAPREDUCE2"
                           }
                        ]
                     }
                  },
                  {
                     "order_id":4,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"HBase Service Check (batch 4 of 13)",
                           "command":"HBASE_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"HBASE"
                           }
                        ]
                     }
                  },
                  {
                     "order_id":5,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"Hive Service Check (batch 5 of 13)",
                           "command":"HIVE_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"HIVE"
                           }
                        ]
                     }
                  },
                  {
                     "order_id":6,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"Oozie Service Check (batch 6 of 13)",
                           "command":"OOZIE_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"OOZIE"
                           }
                        ]
                     }
                  },
                  {
                     "order_id":7,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"Zookeeper Service Check (batch 7 of 13)",
                           "command":"ZOOKEEPER_QUORUM_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"ZOOKEEPER"
                           }
                        ]
                     }
                  },
                  {
                     "order_id":8,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"Tez Service Check (batch 8 of 13)",
                           "command":"TEZ_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"TEZ"
                           }
                        ]
                     }
                  },
                  {
                     "order_id":9,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"Sqoop Service Check (batch 9 of 13)",
                           "command":"SQOOP_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"SQOOP"
                           }
                        ]
                     }
                  },
                  {
                     "order_id":10,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"Kafka Service Check (batch 10 of 13)",
                           "command":"KAFKA_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"KAFKA"
                           }
                        ]
                     }
                  },
                  {
                     "order_id":11,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"Knox Service Check (batch 11 of 13)",
                           "command":"KNOX_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"KNOX"
                           }
                        ]
                     }
                  },
                  {
                     "order_id":12,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"Spark Service Check (batch 12 of 13)",
                           "command":"SPARK_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"SPARK"
                           }
                        ]
                     }
                  },
                  {
                     "order_id":13,
                     "type":"POST",
                     "uri":"/api/v1/clusters/'"${CLUSTER_NAME}"'/requests",
                     "RequestBodyInfo":{
                        "RequestInfo":{
                           "context":"Ranger Service Check (batch 13 of 13)",
                           "command":"RANGER_SERVICE_CHECK"
                        },
                        "Requests/resource_filters":[
                           {
                              "service_name":"RANGER"
                           }
                        ]
                     }
                  }
               ]
            },
            {
               "batch_settings":{
                  "batch_separation_in_seconds":1,
                  "task_failure_tolerance":1
               }
            }
         ]
      }
   }
]'

# Make the curl request
curl -ivk -H "X-Requested-By: ambari" -u "${USERNAME}:${PASSWORD}" -X POST -d "${PAYLOAD}" "${API_ENDPOINT}"
