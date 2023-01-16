#!/bin/sh

#Deploy sql

if [ ! -d json ]; then
  mkdir json
fi
kubectl create ns demo
kubectl apply -f mysql-server.yaml
kubectl apply -f mysql-client.yaml
sleep 10
_COUNTER_=0
while [ `kubectl get pod -n demo | grep mysql-server | awk '{print $3}' ` != "Running" -a $_COUNTER_ -lt "60" ] ; do
       _COUNTER_=$((( _COUNTER_ + 1 )))
       echo mysql server pod is not ready. COUNTER = $_COUNTER_. idle 1 more second ...
       sleep 1
done
_COUNTER_=0
while [ `kubectl get pod -n demo | grep mysql-client | awk '{print $3}' ` != "Running"  -a $_COUNTER_ -lt "60" ] ; do
       _COUNTER_=$((( _COUNTER_ + 1 )))
       echo mysql client pod is not ready. COUNTER = $_COUNTER_. idle 1 more second ...
       sleep 1
done

serverIP=`kubectl get pod -ndemo -l app=mysql-server -ojson | jq -r .items[].status.podIP`

clientPOD=`kubectl get pod -ndemo -l app=mysql-client --no-headers| awk '{print $1}'`

#Test SQL
echo "Testing SQL"

password=1234567890
cmd="mysql -h $serverIP -u root --password=$password -e "exit"" 
kubectl exec -ti -n demo $clientPOD -- sh -c "$cmd" >mysql.log
_COUNTER_=0
while [ `grep HY000 mysql.log | wc -l` = "1"  -a $_COUNTER_ -lt "60" ] ; do
       _COUNTER_=$((( _COUNTER_ + 1 )))
       kubectl exec -ti -n demo $clientPOD -- sh -c "$cmd" >mysql.log
       echo "Mysql server is not running or denying access COUNTER = $_COUNTER_. idle 1 more second ..."
       sleep 1
done

if [ `grep mysql mysql.log | wc -l` = "0" ]; then

   echo "Mysql server is not running or denying access"
   exit
fi
echo mysql --ssl-mode=DISABLED -h serverIP -u root --password=password -e \"select \* from students WHERE id = \'%\' or \'0\'=\'0\'\" > ./sql_inject.sh
sed -i "s/serverIP/$serverIP/" sql_inject.sh
sed -i "s/=password/=$password/" sql_inject.sh
chmod +x sql_inject.sh
kubectl cp sql_inject.sh -n demo $clientPOD:sql_inject.sh

#Create threat
echo "Creating threat"
#cmd="mysql --ssl-mode=DISABLED -h $serverIP -u root --password=$password -e "select * from students WHERE id = '%' or '0'='0'""
kubectl exec -ti -n demo $clientPOD -- sh -c "./sql_inject.sh" >mysql.log

if [ `grep mysql mysql.log | wc -l` = "0" ]; then

   echo "Mysql server is not running or denying access"
   exit
fi
## checking log

port=10443
_DATE_=`date +%Y%m%d_%H%M%S`
### Find leader controller
_controllerIP_=`kubectl get pod -nneuvector -l app=neuvector-controller-pod -o jsonpath='{.items[0].status.podIP}'`
port=10443
curl -k -H "Content-Type: application/json" -d '{"password": {"username": "admin", "password": "admin"}}' "https://$_controllerIP_:$port/v1/auth" > /dev/null 2>&1 > json/token.json
_TOKEN_=`cat json/token.json | jq -r '.token.token'`
curl -k -H "Content-Type: application/json" -H "X-Auth-Token: $_TOKEN_" "https://$_controllerIP_:$port/v1/log/threat" > json/threats.json

sqlinjection_count=`cat json/threats.json  | jq .threats[].name | grep SQL.Injection | wc -l`

_COUNTER_=0
while [ $sqlinjection_count  = "0"  -a $_COUNTER_ -lt "60" ] ; do
       _COUNTER_=$((( _COUNTER_ + 1 )))
       curl -k -H "Content-Type: application/json" -d '{"password": {"username": "admin", "password": "admin"}}' "https://$_controllerIP_:$port/v1/auth" > /dev/null 2>&1 > json/token.json
       _TOKEN_=`cat json/token.json | jq -r '.token.token'`
       curl -k -H "Content-Type: application/json" -H "X-Auth-Token: $_TOKEN_" "https://$_controllerIP_:$port/v1/log/threat" > json/threats.json
       sqlinjection_count=`cat json/threats.json  | jq .threats[].name | grep SQL.Injection | wc -l`
       echo "threat count $sqlinjection_count COUNTER = $_COUNTER_. idle 1 more second ..."
       sleep 1
done

if [ $sqlinjection_count -ge "1" ]; then
  echo "SQL Injection is detected and reported"
  kubectl delete -f mysql-server.yaml
  kubectl delete -f mysql-client.yaml
else
  echo "SQL Injection is not detected"
fi
