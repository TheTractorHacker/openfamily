# Driving reports

Orbitly can summarise driving each week: number of drives, distance, top
speed, and events such as speeding, hard braking, rapid acceleration and
(optional, per person) phone use.

![Weekly driving report](../images/app/driving-report.png)

- Reports need **driving detection** switched on by each driver. Nobody can
  switch it on for someone else.
- In a **Normal** circle the server works the report out from locations.
  In a **Private (phone-to-phone)** circle each phone works out its own report
  and shares only the result, so the numbers can lag and use a little more
  battery. See [Privacy modes explained](privacy-modes.md).
- Phone use is shown as **Off** (not zero) for people who have not turned it on.

Details and thresholds for administrators: [Driving events](../driving.md) and
[Driving sensors](../driving-sensors.md).
